// Coffee Chess Server - SECURE EDITION
import express from 'express';
import { createServer } from 'http';
import { Server } from 'socket.io';
import cors from 'cors';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { Chess } from 'chess.js';
import { ethers } from 'ethers';
import { moduleAddress, moduleAbi } from './coffytokenvemodülabi.js';
import * as dotenv from 'dotenv';
import fs from 'fs';
dotenv.config();

// ============ DEVELOPMENT MODE ============
// Set to true for local testing without blockchain verification
const DEV_MODE = false;

// ============ CONFIGURATION CONSTANTS ============
const PORT = process.env.PORT || 3005;
const RATE_LIMIT_WINDOW_MS = 60000;
const RATE_LIMIT_MAX_REQUESTS = 30;
const RATE_LIMIT_CHAT_MAX = 20;
const RATE_LIMIT_CLEANUP_INTERVAL = 300000; // 5 minutes
const CLEANUP_DELAY_MS = 5000;
const RECONNECT_TIMEOUT_MS = 60000;
const STAKE_VERIFY_MAX_RETRIES = 15;
const STAKE_VERIFY_BASE_DELAY = 3000;
// ===========================================

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ============ USERNAME STORAGE ============
const USERS_FILE = join(__dirname, 'users.json');
let registeredUsers = {}; // walletAddress(lower) -> username

try {
    if (fs.existsSync(USERS_FILE)) {
        const data = fs.readFileSync(USERS_FILE, 'utf8');
        registeredUsers = JSON.parse(data);
        console.log(`✅ Loaded ${Object.keys(registeredUsers).length} registered users`);
    } else {
        fs.writeFileSync(USERS_FILE, JSON.stringify({}, null, 2));
    }
} catch (error) {
    console.error('❌ Error loading users.json:', error);
}

function saveUsers() {
    try {
        fs.writeFileSync(USERS_FILE, JSON.stringify(registeredUsers, null, 2));
    } catch (error) {
        console.error('❌ Error saving users.json:', error);
    }
}
// ===========================================

const app = express();

// CORS ayarları - TÜM originlere izin
// CORS settings - Restricted for security
const allowedOrigins = [
    'http://localhost:3000',
    'http://localhost:5500',
    'http://127.0.0.1:5500',
    'https://coffeechess.com' // Example production domain
];

app.use(cors({
    origin: true, // Her gelen isteğe (localhost, vercel vb) izin ver
    credentials: true,
    methods: ['GET', 'POST', 'OPTIONS']
}));

app.use(express.json());
app.use(express.static(__dirname));

app.get('/favicon.ico', (req, res) => res.status(204).end());

const server = createServer(app);

// Socket.IO CORS ayarları - GELİŞTİRİLMİŞ
const io = new Server(server, {
    cors: {
        origin: '*', // Tüm originlere izin
        methods: ['GET', 'POST', 'OPTIONS'],
        credentials: true,
        allowedHeaders: ['Content-Type']
    },
    transports: ['websocket', 'polling'], // Her iki transport'u destekle
    allowEIO3: true // Socket.io v3 uyumluluğu
});

// Multi-RPC fallback for better reliability
const RPC_URLS = [
    'https://mainnet.base.org',
    'https://base.meowrpc.com',
    'https://base.publicnode.com'
];

let provider;
let moduleContract;

async function initializeProvider() {
    for (const url of RPC_URLS) {
        try {
            const testProvider = new ethers.providers.JsonRpcProvider(url);
            await testProvider.getNetwork();
            provider = testProvider;
            console.log(`✅ Connected to Base RPC: ${url}`);
            return;
        } catch (error) {
            console.warn(`⚠️ Failed to connect to ${url}, trying next...`);
        }
    }
    throw new Error('❌ Could not connect to any Base RPC endpoint');
}

// Storage
const rooms = new Map();
const playerSessions = new Map(); // walletAddress -> { socketId, roomId, reconnectTimer }
let roomCounter = 1;

function generateRoomId() {
    return 'CHESS-' + String(roomCounter++).padStart(4, '0');
}

// Health check
app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        game: 'Coffee Chess Secure',
        rooms: rooms.size,
        activePlayers: playerSessions.size
    });
});

// List rooms API
app.get('/rooms', (req, res) => {
    const openRooms = [];
    rooms.forEach((room, roomId) => {
        if (!room.started) {
            openRooms.push({
                roomId,
                playersCount: room.players.length,
                meta: room.meta
            });
        }
    });
    res.json(openRooms);
});

// Rate limiting storage
const rateLimits = new Map(); // socketId -> { count, resetTime }

// Rate limiter middleware
function checkRateLimit(socketId, maxRequests = RATE_LIMIT_MAX_REQUESTS, windowMs = RATE_LIMIT_WINDOW_MS) {
    const now = Date.now();
    const limit = rateLimits.get(socketId);

    if (!limit || now > limit.resetTime) {
        rateLimits.set(socketId, { count: 1, resetTime: now + windowMs });
        return true;
    }

    if (limit.count >= maxRequests) {
        return false;
    }

    limit.count++;
    return true;
}

// Cleanup rate limits periodically to prevent memory leaks
setInterval(() => {
    const now = Date.now();
    let cleanedCount = 0;
    for (const [key, limit] of rateLimits.entries()) {
        if (now > limit.resetTime) {
            rateLimits.delete(key);
            cleanedCount++;
        }
    }
    if (cleanedCount > 0) {
        console.log(`🧹 Cleaned up ${cleanedCount} expired rate limit entries`);
    }
}, RATE_LIMIT_CLEANUP_INTERVAL);

// Verify stake on blockchain
// CoffyBattleV3 battles mapping: [battleId, initiator, opponent, stakeAmount, status, winner, createdAt, expiresAt, commitDeadline, revealDeadline]
// BattleStatus enum: 0=Pending, 1=Active, 2=Committed, 3=Completed, 4=Cancelled, 5=Expired
async function verifyStake(gameId, playerAddress, expectedStake) {
    for (let attempt = 1; attempt <= STAKE_VERIFY_MAX_RETRIES; attempt++) {
        try {
            console.log(`🔍 Verifying stake for game ${gameId}, player ${playerAddress} (Attempt ${attempt}/${STAKE_VERIFY_MAX_RETRIES})`);

            const g = await moduleContract.getGameInfo(gameId);
            // g = [player1, player2, stakePerPlayer, totalStaked, createdAt, status, winner]

            const player1 = g[0].toLowerCase();
            const player2 = g[1].toLowerCase();
            const stakePerPlayer = g[2]; // BigNumber
            const status = Number(g[5]);

            // Oyuncu katılımcı mı?
            const addr = playerAddress.toLowerCase();
            if (player1 !== addr && player2 !== addr) {
                console.log(`⚠️ Player not found in game yet, retrying...`);
                if (attempt < STAKE_VERIFY_MAX_RETRIES) {
                    await new Promise(r => setTimeout(r, attempt * STAKE_VERIFY_BASE_DELAY));
                    continue;
                }
                return false;
            }

            // Status completed/cancelled mı?
            if (status >= 2) {
                console.log(`❌ Game ${gameId} already done (status: ${status})`);
                return false;
            }

            console.log(`✅ Game ${gameId} verified for ${playerAddress}`);
            return true;

        } catch (error) {
            console.error(`Attempt ${attempt} error:`, error.message);
            if (attempt < STAKE_VERIFY_MAX_RETRIES) {
                await new Promise(r => setTimeout(r, attempt * STAKE_VERIFY_BASE_DELAY));
            }
        }
    }
    return false;
}

// Socket handlers
io.on('connection', (socket) => {
    console.log('👤 Connected:', socket.id);
    let currentRoom = null;
    let playerNum = null;
    let walletAddress = null;

    // Create room
    socket.on('createRoom', async (data, callback) => {
        console.log('📥 createRoom request received:', { gameId: data.gameId, wallet: data.walletAddress, stake: data.stake });
        walletAddress = data.walletAddress.toLowerCase();

        // Check if player already has an active session
        if (playerSessions.has(walletAddress)) {
            const existingSession = playerSessions.get(walletAddress);
            if (rooms.has(existingSession.roomId)) {
                callback({ error: 'You already have an active game', roomId: existingSession.roomId });
                return;
            }
        }

        // Optimistic Room Creation: Don't wait for blockchain (it takes too long)
        const roomId = generateRoomId();
        const timeLimit = data.timeLimit || 5; // Default to 5 minutes
        const initialTime = timeLimit * 60;

        const room = {
            id: roomId,
            players: [{
                id: socket.id,
                address: walletAddress,
                color: 'white'
            }],
            meta: {
                gameId: data.gameId,
                stake: data.stake,
                timeLimit: timeLimit,
                createdAt: Date.now()
            },
            chess: new Chess(),
            timers: { white: initialTime, black: initialTime, interval: null, turn: 'w' },
            moves: [],
            chatMessages: [],
            started: false,
            gameOver: false,
            lastMoveTime: Date.now(),
            verified: false // New flag
        };

        rooms.set(roomId, room);
        socket.join(roomId);
        currentRoom = roomId;
        playerNum = 1;

        // Register session
        playerSessions.set(walletAddress, {
            socketId: socket.id,
            roomId,
            reconnectTimer: null
        });

        console.log(`📦 Room ${roomId} created OPTIMISTICALLY by ${walletAddress} (GameID: ${data.gameId})`);

        // Respond IMMEDIATELY to client
        callback({ success: true, roomId });

        // Background Verification
        if (!DEV_MODE) {
            verifyStake(data.gameId, walletAddress, data.stake).then(stakeVerified => {
                if (!stakeVerified) {
                    console.log(`❌ Background verification failed for ${roomId}. Closing room.`);
                    io.to(roomId).emit('error', { message: 'Stake verification failed. Room closing.' });
                    io.to(roomId).emit('gameCancelled', { reason: 'Stake verification failed' });
                    cleanupRoom(roomId);
                } else {
                    console.log(`✅ Background verification SUCCESS for ${roomId}`);
                    const r = rooms.get(roomId);
                    if (r) r.verified = true;
                }
            });
        } else {
            room.verified = true;
        }
    });

    // Join room
    socket.on('joinRoom', async (data, callback) => {
        const { roomId: targetRoomId, walletAddress: joinWallet, gameId } = data;
        walletAddress = joinWallet.toLowerCase();

        const room = rooms.get(targetRoomId);

        if (!room) {
            callback({ error: 'Room not found' });
            return;
        }

        if (room.players.length >= 2) {
            callback({ error: 'Room is full' });
            return;
        }

        if (room.started) {
            callback({ error: 'Game already started' });
            return;
        }

        // Optimistic Join: Verify stake in background
        if (!DEV_MODE) {
            verifyStake(gameId, walletAddress, room.meta.stake).then(stakeVerified => {
                if (!stakeVerified) {
                    console.log(`❌ Background verification failed for JOINER ${walletAddress} in room ${targetRoomId}`);
                    io.to(targetRoomId).emit('error', { message: 'Opponent stake verification failed. Game cancelled.' });
                    io.to(targetRoomId).emit('gameCancelled', { reason: 'Opponent stake verification failed' });
                    cleanupRoom(targetRoomId);
                } else {
                    console.log(`✅ Background verification SUCCESS for JOINER ${walletAddress}`);
                }
            });
        }

        // Anti-cheat: Check if same wallet is trying to join
        if (room.players[0].address === walletAddress) {
            callback({ error: 'Cannot play against yourself' });
            return;
        }

        room.players.push({
            id: socket.id,
            address: walletAddress,
            color: 'black'
        });
        socket.join(targetRoomId);
        currentRoom = targetRoomId;
        playerNum = 2;

        // Register session
        playerSessions.set(walletAddress, {
            socketId: socket.id,
            roomId: targetRoomId,
            reconnectTimer: null
        });

        room.started = true;

        // Timer will be started after the first move to prevent race conditions
        // startRoomTimer(targetRoomId);

        // Emit startGame to each player with their specific data
        // Player 1 (White)
        io.to(room.players[0].id).emit('startGame', {
            playerNumber: 1,
            color: 'white',
            opponent: room.players[1].address,
            timers: { white: room.timers.white, black: room.timers.black },
            chatHistory: room.chatMessages,
            gameId: room.meta.gameId,
            meta: room.meta
        });

        // Player 2 (Black)
        io.to(room.players[1].id).emit('startGame', {
            playerNumber: 2,
            color: 'black',
            opponent: room.players[0].address,
            timers: { white: room.timers.white, black: room.timers.black },
            chatHistory: room.chatMessages,
            gameId: room.meta.gameId,
            meta: room.meta
        });

        console.log(`🎮 Game started in ${targetRoomId}`);
        callback({ success: true });
    });

    // Move (Client sends 'makeMove')
    socket.on('makeMove', (data) => {
        if (!checkRateLimit(socket.id, RATE_LIMIT_MAX_REQUESTS, 10000)) { // 30 moves per 10 seconds max
            socket.emit('moveRejected', { reason: 'Too many moves. Slow down!' });
            return;
        }

        if (!currentRoom) return;
        const room = rooms.get(currentRoom);
        if (!room || !room.started || room.gameOver) return;

        // Security: Verify player is in this room
        const player = room.players.find(p => p.id === socket.id);
        if (!player) {
            socket.emit('moveRejected', { reason: 'You are not in this game' });
            return;
        }

        // Security: Verify it's player's turn
        const currentTurn = room.chess.turn();
        const playerColor = player.color === 'white' ? 'w' : 'b';
        if (currentTurn !== playerColor) {
            socket.emit('moveRejected', { reason: 'Not your turn' });
            return;
        }

        try {
            // Validate move using server-side chess instance
            const move = room.chess.move(data.move);

            if (!move) {
                socket.emit('moveRejected', { reason: 'Invalid move' });
                return;
            }

            // Move is valid, broadcast to all
            room.moves.push(move);
            room.lastMoveTime = Date.now();

            // Ensure timer is running (starts after first move)
            if (!room.timers.interval) {
                startRoomTimer(currentRoom);
            }

            io.to(currentRoom).emit('moveAccepted', {
                move: move,
                fen: room.chess.fen(),
                pgn: room.chess.pgn(),
                playerNum: playerNum,
                turn: room.chess.turn()
            });

            // Check for game end
            let winner = null;
            let reason = '';
            const currentColor = room.chess.turn();

            console.log(`📊 After move - checking game state: in_checkmate=${room.chess.in_checkmate()}, in_draw=${room.chess.in_draw()}, turn=${currentColor}`);

            if (room.chess.in_checkmate()) {
                winner = currentColor === 'w' ? 'black' : 'white';
                reason = 'checkmate';
                console.log(`♚ CHECKMATE detected! Winner: ${winner}`);
            } else if (room.chess.in_draw()) {
                winner = 'draw';
                reason = room.chess.in_stalemate() ? 'stalemate' :
                    room.chess.in_threefold_repetition() ? 'repetition' :
                        room.chess.insufficient_material() ? 'insufficient material' : 'draw';
                console.log(`🤝 DRAW detected! Reason: ${reason}`);
            }

            if (winner !== null) {
                console.log(`🏁 Calling handleGameEnd for room ${currentRoom}, winner: ${winner}`);
                handleGameEnd(currentRoom, winner, reason);
            }
        } catch (error) {
            socket.emit('moveRejected', { reason: 'Invalid move format' });
            console.error('Move error:', error);
        }
    });

    // Resign
    socket.on('resign', () => {
        if (!currentRoom) return;
        const room = rooms.get(currentRoom);
        if (!room || room.gameOver) return;

        const winner = playerNum === 1 ? 'black' : 'white';
        handleGameEnd(currentRoom, winner, 'resignation');
    });

    // --- DRAW OFFER LOGIC ---
    socket.on('offerDraw', () => {
        if (!currentRoom) return;
        const room = rooms.get(currentRoom);
        if (!room || room.gameOver) return;

        // Prevent spam or multiple offers
        if (room.pendingDrawOffer) return;

        // Record who offered the draw
        room.pendingDrawOffer = socket.id;

        // Add 30 second timeout safeguard to prevent draw abuse
        room.drawOfferTimeout = setTimeout(() => {
            if (room.pendingDrawOffer === socket.id) { // Ensure hasn't been resolved
                room.pendingDrawOffer = null;
                console.log(`⏰ Draw offer expired in room ${currentRoom}`);
                io.to(socket.id).emit('drawDeclined'); // Send decline event back to offerer
            }
        }, 30000);

        // Find the opponent's socket and emit 'drawOffered'
        const opponent = room.players.find(p => p.id !== socket.id);
        if (opponent) {
            io.to(opponent.id).emit('drawOffered');
            console.log(`🤝 Draw offered by player in room ${currentRoom}`);
        }
    });

    socket.on('acceptDraw', () => {
        if (!currentRoom) return;
        const room = rooms.get(currentRoom);
        if (!room || room.gameOver) return;

        // Ensure there is a pending offer from the OPPONENT
        if (!room.pendingDrawOffer || room.pendingDrawOffer === socket.id) return;

        // Clear timer and offer state
        if (room.drawOfferTimeout) clearTimeout(room.drawOfferTimeout);
        room.pendingDrawOffer = null;
        console.log(`🤝 Draw accepted in room ${currentRoom}`);

        // Both players agreed -> mutual draw
        handleGameEnd(currentRoom, 'draw', 'mutual agreement');
    });

    socket.on('declineDraw', () => {
        if (!currentRoom) return;
        const room = rooms.get(currentRoom);
        if (!room || room.gameOver) return;

        // Ensure there is a pending offer from the OPPONENT
        if (!room.pendingDrawOffer || room.pendingDrawOffer === socket.id) return;

        // Clear timer and offer state
        if (room.drawOfferTimeout) clearTimeout(room.drawOfferTimeout);
        room.pendingDrawOffer = null;
        console.log(`❌ Draw declined in room ${currentRoom}`);

        // Notify the opponent who made the offer that it was declined
        const opponent = room.players.find(p => p.id !== socket.id);
        if (opponent) {
            io.to(opponent.id).emit('drawDeclined');
        }
    });

    // Chat message
    socket.on('chatMessage', (data) => {
        // Rate limit check for chat
        if (!checkRateLimit(socket.id + '_chat', RATE_LIMIT_CHAT_MAX, 60000)) { // 20 messages per minute max
            socket.emit('chatError', { reason: 'Too many messages. Please slow down.' });
            return;
        }

        if (!currentRoom || !walletAddress) return;
        const room = rooms.get(currentRoom);
        if (!room) return;

        // Enhanced input validation
        let message = data.message;
        if (typeof message !== 'string') return;

        message = message.trim();
        if (!message || message.length === 0 || message.length > 200) return;

        // XSS protection - sanitize HTML tags
        message = message
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#x27;')
            .replace(/\//g, '&#x2F;');

        // Basic profanity filter
        const profanityList = ['spam', 'scam', 'hack', 'cheat'];
        const lowerMsg = message.toLowerCase();
        for (const word of profanityList) {
            if (lowerMsg.includes(word)) {
                message = message.replace(new RegExp(word, 'gi'), '***');
            }
        }

        // Determine sender name (use registered username if available)
        const lowerWallet = walletAddress.toLowerCase();
        const senderDisplay = registeredUsers[lowerWallet] || `${walletAddress.slice(0, 6)}...${walletAddress.slice(-4)}`;

        const chatMsg = {
            id: Date.now() + Math.random(),
            sender: walletAddress,
            senderShort: senderDisplay,
            playerNum: playerNum,
            message: message,
            timestamp: Date.now()
        };

        room.chatMessages.push(chatMsg);

        // Keep only last 100 messages
        if (room.chatMessages.length > 100) {
            room.chatMessages.shift();
        }

        // Broadcast to room
        io.to(currentRoom).emit('chatMessage', chatMsg);

        console.log(`💬 Chat in ${currentRoom} from Player${playerNum} (${senderDisplay}): ${message}`);
    });

    // --- Usernames logic ---
    socket.on('checkUsername', (data, callback) => {
        if (!data || !data.walletAddress) return callback({ error: 'No wallet provided' });
        const wallet = data.walletAddress.toLowerCase();

        if (registeredUsers[wallet]) {
            callback({ success: true, username: registeredUsers[wallet] });
        } else {
            callback({ success: false, error: 'No username registered' });
        }
    });

    socket.on('setUsername', (data, callback) => {
        // Simple rate limiting to prevent spamming names
        if (!checkRateLimit(socket.id + '_setname', 5, 60000)) {
            return callback({ success: false, error: 'Too many requests' });
        }

        const wallet = data.walletAddress?.toLowerCase();
        let desiredName = data.username;

        if (!wallet || !desiredName) return callback({ success: false, error: 'Missing data' });

        // Check if wallet already has a name
        if (registeredUsers[wallet]) {
            return callback({ success: false, error: 'This wallet already has a registered username' });
        }

        desiredName = desiredName.trim();
        if (desiredName.length < 3 || desiredName.length > 15) {
            return callback({ success: false, error: 'Username must be between 3 and 15 characters' });
        }

        // Alphanumeric only
        if (!/^[a-zA-Z0-9_]+$/.test(desiredName)) {
            return callback({ success: false, error: 'Username can only contain letters, numbers, and underscores' });
        }

        // Check uniqueness
        const lowerDesired = desiredName.toLowerCase();
        const isTaken = Object.values(registeredUsers).some(name => name.toLowerCase() === lowerDesired);

        if (isTaken) {
            return callback({ success: false, error: 'This username is already taken' });
        }

        // Register it
        registeredUsers[wallet] = desiredName;
        saveUsers();
        console.log(`🏷️  User Registered: ${wallet} -> ${desiredName}`);

        callback({ success: true, username: desiredName });
    });

    // --- Connection Ping/Pong for Latency ---
    socket.on('pingHeartbeat', (clientTime) => {
        socket.emit('pongHeartbeat', clientTime); // Echo back immediately
    });

    // List rooms
    socket.on('listRooms', (callback) => {
        const openRooms = [];
        rooms.forEach((room, roomId) => {
            if (!room.started && room.players.length < 2) {
                openRooms.push({
                    roomId,
                    playersCount: room.players.length,
                    meta: room.meta
                });
            }
        });
        callback(openRooms);
    });

    // Get room info by roomId - for joining
    socket.on('getRoomInfo', (roomId, callback) => {
        const room = rooms.get(roomId);
        if (!room) {
            callback({ error: 'Room not found' });
            return;
        }
        if (room.started || room.players.length >= 2) {
            callback({ error: 'Room is full or game already started' });
            return;
        }
        callback({
            roomId: roomId,
            gameId: room.meta?.gameId,
            stake: room.meta?.stake,
            timeLimit: room.meta?.timeLimit,
            playersCount: room.players.length
        });
    });

    // Find room by blockchain gameId
    socket.on('findRoomByGameId', (gameId, callback) => {
        console.log(`🔍 Searching for room with gameId: ${gameId}`);

        let foundRoom = null;
        let foundRoomId = null;

        rooms.forEach((room, roomId) => {
            // Compare as strings since gameId might be number or string
            if (room.meta?.gameId?.toString() === gameId?.toString()) {
                if (!room.started && room.players.length < 2) {
                    foundRoom = room;
                    foundRoomId = roomId;
                }
            }
        });

        if (!foundRoom) {
            console.log(`❌ No room found for gameId: ${gameId}`);
            console.log(`📋 Current rooms:`, Array.from(rooms.entries()).map(([id, r]) => ({ roomId: id, gameId: r.meta?.gameId, started: r.started, players: r.players.length })));
            callback({ error: 'No open room found for this Game ID' });
            return;
        }

        console.log(`✅ Found room ${foundRoomId} for gameId: ${gameId}`);
        callback({
            roomId: foundRoomId,
            gameId: foundRoom.meta?.gameId,
            stake: foundRoom.meta?.stake,
            timeLimit: foundRoom.meta?.timeLimit,
            playersCount: foundRoom.players.length
        });
    });

    // Reconnect - Handle player returning to an ongoing game
    socket.on('reconnect', async (data, callback) => {
        const reconnectWallet = data.walletAddress?.toLowerCase();
        const signature = data.signature;
        if (!reconnectWallet) {
            callback({ success: false, error: 'No wallet address provided' });
            return;
        }

        // BUG-08 FIX: Verify signature to prevent impersonation
        if (signature) {
            try {
                const recovered = ethers.utils.verifyMessage('Reconnecting to CoffeeChess', signature).toLowerCase();
                if (recovered !== reconnectWallet) {
                    callback({ success: false, error: 'Signature mismatch — unauthorized reconnect' });
                    return;
                }
            } catch (sigErr) {
                console.warn('Signature verification error:', sigErr.message);
                callback({ success: false, error: 'Invalid signature' });
                return;
            }
        }

        const session = playerSessions.get(reconnectWallet);
        if (!session || !session.roomId) {
            callback({ success: false, error: 'No active session found' });
            return;
        }

        const room = rooms.get(session.roomId);
        if (!room) {
            playerSessions.delete(reconnectWallet);
            callback({ success: false, error: 'Game room no longer exists' });
            return;
        }

        // Clear any pending disconnect timer
        if (session.reconnectTimer) {
            clearTimeout(session.reconnectTimer);
            session.reconnectTimer = null;
        }

        // Find player in room and update socket ID
        const player = room.players.find(p => p.address === reconnectWallet);
        if (!player) {
            callback({ success: false, error: 'Player not found in room' });
            return;
        }

        const oldSocketId = player.id;
        player.id = socket.id;
        session.socketId = socket.id;

        // Update closure variables
        currentRoom = session.roomId;
        walletAddress = reconnectWallet;
        playerNum = player.color === 'white' ? 1 : 2;

        // Rejoin socket room
        socket.join(session.roomId);

        // Notify opponent that player reconnected
        const opponent = room.players.find(p => p.address !== reconnectWallet);
        if (opponent) {
            io.to(opponent.id).emit('opponentReconnected', {
                message: 'Opponent has reconnected!'
            });
        }

        console.log(`🔄 Player ${reconnectWallet} reconnected to ${session.roomId}`);

        // Return complete game state to reconnecting player
        callback({
            success: true,
            roomId: session.roomId,
            playerNumber: playerNum,
            color: player.color,
            gameId: room.meta?.gameId,
            fen: room.chess.fen(),
            pgn: room.chess.pgn(),
            timers: { white: room.timers.white, black: room.timers.black },
            chatHistory: room.chatMessages || [],
            gameOver: room.gameOver,
            winner: room.winner,
            reason: room.endReason,
            opponent: opponent?.address,
            signatureWhite: room.signatureWhite,
            signatureBlack: room.signatureBlack
        });
    });

    // Disconnect
    socket.on('disconnect', () => {
        console.log('👋 Disconnected:', socket.id);

        if (currentRoom && walletAddress) {
            const room = rooms.get(currentRoom);
            if (room && !room.gameOver) {

                // Notify opponent about disconnect
                const opponentId = room.players.find(p => p.address !== walletAddress)?.id;
                if (opponentId) {
                    io.to(opponentId).emit('opponentDisconnected', {
                        message: 'Opponent disconnected. They have 60 seconds to reconnect.'
                    });
                }

                // Set reconnection timer (60 seconds)
                const session = playerSessions.get(walletAddress);
                if (session) {
                    session.reconnectTimer = setTimeout(() => {
                        // If still not reconnected after 60s
                        if (rooms.has(currentRoom)) {
                            const winner = playerNum === 1 ? 'black' : 'white';
                            handleGameEnd(currentRoom, winner, 'disconnect');

                            // Cleanup
                            cleanupRoom(currentRoom);
                        }
                    }, RECONNECT_TIMEOUT_MS);
                }
            } else if (room && room.gameOver) {
                // Game already over, cleanup immediately
                setTimeout(() => cleanupRoom(currentRoom), CLEANUP_DELAY_MS);
            }
        }
    });
});

async function handleGameEnd(roomId, winner, reason) {
    const room = rooms.get(roomId);
    if (!room || room.gameOver) return;

    console.log(`🏁 Game ended in ${roomId}: ${winner} wins (${reason})`);

    room.gameOver = true;
    // BUG-12 FIX: save winner/reason so reconnect handler can return them
    room.winner = winner;
    room.endReason = reason;
    room.signatureWhite = null;
    room.signatureBlack = null;

    if (room.timers.interval) {
        clearInterval(room.timers.interval);
        room.timers.interval = null;
    }

    // Calculate scores for Commit-Reveal
    // Winner: 1000, Loser: 0, Draw: 500
    let whiteScore = 0;
    let blackScore = 0;

    if (winner === 'white') {
        whiteScore = 1000;
        blackScore = 0;
    } else if (winner === 'black') {
        whiteScore = 0;
        blackScore = 1000;
    } else {
        // Draw
        whiteScore = 500;
        blackScore = 500;
    }

    // Find players by color to ensure correct address assignment
    const whitePlayer = room.players.find(p => p.color === 'white');
    const blackPlayer = room.players.find(p => p.color === 'black');
    const winnerAddress = winner === 'white' ? whitePlayer?.address :
        winner === 'black' ? blackPlayer?.address : null;

    let signatureWhite = null;
    let signatureBlack = null;

    if (winner !== 'draw') {
        try {
            if (!process.env.SIGNER_PRIVATE_KEY) {
                console.error("❌ SIGNER_PRIVATE_KEY not found in environment. Cannot sign game win.");
            } else {
                const signer = new ethers.Wallet(process.env.SIGNER_PRIVATE_KEY);
                const gameId = room.meta?.gameId;

                if (gameId) {
                    // ABI Encode: keccak256(abi.encodePacked("GAME_WIN", gameId, winnerAddress, chainId, contractAddress))
                    const network = await provider.getNetwork();
                    const chainId = ethers.BigNumber.from(network.chainId);
                    const parsedGameId = ethers.BigNumber.from(gameId);
                    const checksumWinnerAddress = ethers.utils.getAddress(winnerAddress);

                    console.log("🔏 İmza parametreleri (WINNER):", {
                        gameId: parsedGameId.toString(),
                        winnerAddress: checksumWinnerAddress,
                        chainId: chainId.toString(),
                        moduleAddress: moduleAddress
                    });

                    const messageHash = ethers.utils.solidityKeccak256(
                        ['string', 'uint256', 'address', 'uint256', 'address'],
                        ['GAME_WIN', parsedGameId, checksumWinnerAddress, chainId, moduleAddress]
                    );

                    const messageHashBytes = ethers.utils.arrayify(messageHash);

                    if (winner === 'white') {
                        signatureWhite = await signer.signMessage(messageHashBytes);
                    } else {
                        signatureBlack = await signer.signMessage(messageHashBytes);
                    }
                    console.log(`✅ GAME_WIN Signature created for ${winnerAddress}`);
                }
            }
        } catch (error) {
            console.error("❌ Signature generation error:", error);
        }
    } else {
        // Handle Draw condition - Generate signatures for both players
        try {
            if (!process.env.SIGNER_PRIVATE_KEY) {
                console.error("❌ SIGNER_PRIVATE_KEY not found in environment. Cannot sign game draw.");
            } else {
                const signer = new ethers.Wallet(process.env.SIGNER_PRIVATE_KEY);
                const gameId = room.meta?.gameId;

                if (gameId && whitePlayer?.address && blackPlayer?.address) {
                    const network = await provider.getNetwork();
                    const chainId = ethers.BigNumber.from(network.chainId);
                    const parsedGameId = ethers.BigNumber.from(gameId);
                    const checksumWhiteAddress = ethers.utils.getAddress(whitePlayer.address);
                    const checksumBlackAddress = ethers.utils.getAddress(blackPlayer.address);

                    // Sign for White
                    const messageHashWhite = ethers.utils.solidityKeccak256(
                        ['string', 'uint256', 'address', 'uint256', 'address'],
                        ['GAME_DRAW', parsedGameId, checksumWhiteAddress, chainId, moduleAddress]
                    );
                    signatureWhite = await signer.signMessage(ethers.utils.arrayify(messageHashWhite));

                    // Sign for Black
                    const messageHashBlack = ethers.utils.solidityKeccak256(
                        ['string', 'uint256', 'address', 'uint256', 'address'],
                        ['GAME_DRAW', parsedGameId, checksumBlackAddress, chainId, moduleAddress]
                    );
                    signatureBlack = await signer.signMessage(ethers.utils.arrayify(messageHashBlack));

                    console.log(`✅ GAME_DRAW Signatures created for both players`);
                }
            }
        } catch (error) {
            console.error("❌ Draw signature generation error:", error);
        }
    }

    // Save generated signatures directly to the room for reconnect caching
    room.signatureWhite = signatureWhite;
    room.signatureBlack = signatureBlack;

    io.to(roomId).emit('gameEnded', {
        winner,
        reason,
        pgn: room.chess.pgn(),
        gameId: room.meta?.gameId,
        winnerAddress: winnerAddress || null,
        scores: {
            white: whiteScore,
            black: blackScore
        },
        signatureWhite: signatureWhite,
        signatureBlack: signatureBlack
    });

    // BUG-10 FIX: schedule cleanup so room doesn't stay in memory forever
    // 30s delay allows pending reconnection attempts to still see the room
    setTimeout(() => cleanupRoom(roomId), 30000);
}

function startRoomTimer(roomId) {
    const room = rooms.get(roomId);
    if (!room || room.timers.interval) return; // Prevent multiple intervals

    room.timers.interval = setInterval(() => {
        if (room.gameOver) {
            clearInterval(room.timers.interval);
            return;
        }

        // Decrement timer for the player whose turn it currently is
        // Same logic as the working AI local timer (startLocalTimer)
        if (room.chess.history().length > 0) {
            if (room.chess.turn() === 'w') {
                room.timers.white--;
            } else {
                room.timers.black--;
            }
        }

        io.to(roomId).emit('timerUpdate', {
            white: room.timers.white,
            black: room.timers.black
        });

        if (room.timers.white <= 0) {
            handleGameEnd(roomId, 'black', 'timeout');
            return; // BUG-11 FIX: stop this tick immediately
        } else if (room.timers.black <= 0) {
            handleGameEnd(roomId, 'white', 'timeout');
            return; // BUG-11 FIX: stop this tick immediately
        }
    }, 1000);
}

function cleanupRoom(roomId) {
    const room = rooms.get(roomId);
    if (!room) return;

    // Clear timers
    if (room.timers.interval) {
        clearInterval(room.timers.interval);
    }

    // Remove player sessions
    room.players.forEach(player => {
        if (player.address) {
            const session = playerSessions.get(player.address);
            if (session?.reconnectTimer) {
                clearTimeout(session.reconnectTimer);
            }
            playerSessions.delete(player.address);
        }
    });

    // Delete room
    rooms.delete(roomId);
    console.log(`🗑️ Room ${roomId} cleaned up`);
}

// Initialize provider and start server
async function startServer() {
    try {
        await initializeProvider();

        moduleContract = new ethers.Contract(moduleAddress, moduleAbi, provider);

        if (process.env.SIGNER_PRIVATE_KEY) {
            const tempSigner = new ethers.Wallet(process.env.SIGNER_PRIVATE_KEY);
            try {
                const onChainSigner = await moduleContract.trustedSigner();
                if (tempSigner.address.toLowerCase() === onChainSigner.toLowerCase()) {
                    console.log(`✅ Trusted Signer matches: ${tempSigner.address}`);
                } else {
                    console.error(`❌ CRITICAL: SIGNER_PRIVATE_KEY address (${tempSigner.address}) DOES NOT MATCH on-chain trustedSigner (${onChainSigner})! Signatures will revert.`);
                }
            } catch (err) {
                console.warn(`⚠️ Could not verify trustedSigner on-chain: ${err.message}`);
            }
        } else {
            console.warn(`⚠️ SIGNER_PRIVATE_KEY is missing from .env! You will not be able to claim games.`);
        }

        server.listen(PORT, '0.0.0.0', () => { // 0.0.0.0 ile tüm network interfacelerini dinle
            console.log(`
╔═══════════════════════════════════════════════════╗
║      ♔  COFFEE CHESS SECURE SERVER  ♚            ║
║      ✓ Server-side chess validation              ║
║      ✓ Blockchain stake verification             ║
║      ✓ Reconnection support (60s window)         ║
║      ✓ Anti-cheat protection                     ║
║      ✓ Multi-RPC fallback                        ║
║      ✓ CORS enabled for all origins              ║
║      ✓ Trusted signature backend                 ║
║      Running on port ${PORT}                          ║
║      http://localhost:${PORT}                         ║
║      http://127.0.0.1:${PORT}                         ║
╚═══════════════════════════════════════════════════╝
            `);
        });
    } catch (error) {
        console.error('❌ Failed to start server:', error.message);
        process.exit(1);
    }
}

startServer();
