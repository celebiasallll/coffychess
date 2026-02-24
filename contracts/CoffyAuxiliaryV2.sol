// SPDX-License-Identifier: MIT
// Network: Base (Coinbase L2)
// CoffyAuxiliary V2 — Backend-Signed Game Module
// Commit-reveal kaldırıldı, backend imza doğrulamasıyla değiştirildi
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface ICoffyTokenV2 {
    function burnFromGame(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function getUserCharacterBalance(address user, uint256 characterId) external view returns (uint256);
    function transferCharacterForModule(address from, address to, uint256 characterId, uint128 amount) external;
    function treasury() external view returns (address);
}

/**
 * @title CoffyAuxiliary V2 — Backend-Signed Game Module
 * @dev Tüm oyun sonuçları backend tarafından imzalanır, kontrat doğrular.
 *
 * Akış:
 *   1. createGame / joinGame → stake yatırılır (kullanıcı approve + TX)
 *   2. Oyun off-chain oynanır (server doğrular)
 *   3. Backend kazananı imzalar (ücretsiz, gas yok)
 *   4. Kazanan claimGameWin(gameId, signature) çağırır (tek TX)
 *
 * Güvenlik:
 *   - ECDSA imza doğrulaması (OpenZeppelin)
 *   - chainId + contractAddress ile replay koruması
 *   - Tip prefixi ile cross-claim koruması (GAME_WIN vs BATTLE_WIN vs SESSION)
 *   - ReentrancyGuard + Pausable
 */
contract CoffyAuxiliaryV2 is AccessControl, ReentrancyGuard, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    ICoffyTokenV2 public coffyToken;
    IERC20 public coffyERC20; // IERC20 cast — transfer/transferFrom için
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ── Backend Signer ──────────────────────────────────────────────────
    address public trustedSigner;

    // ── Global Stake Tracking ───────────────────────────────────────────
    uint256 public totalLockedStakes; // Aktif oyun/battle/queue'daki kilitli stake'ler

    // ══════════════════════════════════════════════════════════════════════
    //                          PVP GAMES
    // ══════════════════════════════════════════════════════════════════════

    struct Game {
        address player1;
        address player2;
        uint128 stakePerPlayer;
        uint128 totalStaked;
        uint64 createdAt;
        uint8 status; // 0=Pending, 1=Active, 2=Completed, 3=Cancelled
        address winner;
    }

    mapping(uint256 => Game) public games;
    mapping(uint256 => mapping(address => bool)) public hasClaimedGame;
    uint256 public nextGameId = 1;
    uint16 public gameFee = 500; // 5%

    // ══════════════════════════════════════════════════════════════════════
    //                          BATTLES
    // ══════════════════════════════════════════════════════════════════════

    struct Battle {
        address initiator;
        address opponent;
        uint128 stakeAmount;
        uint64 createdAt;
        uint64 expiresAt;
        uint8 status; // 0=Pending, 1=Active, 2=Completed, 3=Cancelled
        address winner;
    }

    mapping(uint256 => Battle) public battles;
    mapping(uint256 => mapping(address => bool)) public hasClaimedBattle;
    uint256 public nextBattleId = 1;
    uint16 public battleFee = 500; // 5%
    uint32 public battleExpiration = 24 hours;

    // ══════════════════════════════════════════════════════════════════════
    //                        QUICK MATCH
    // ══════════════════════════════════════════════════════════════════════

    struct QueueEntry {
        address player;
        uint128 stake;
        uint64 queuedAt;
        bool active;
    }

    mapping(uint256 => QueueEntry) public matchQueue;
    uint256 public nextQueueId = 1;
    uint32 public queueExpiration = 10 minutes;

    // ══════════════════════════════════════════════════════════════════════
    //                          MARKETPLACE
    // ══════════════════════════════════════════════════════════════════════

    struct MarketplaceItem {
        address seller;
        uint8 characterId;
        uint128 amount;
        uint128 pricePerUnit;
        bool isActive;
    }

    mapping(uint256 => MarketplaceItem) public marketplaceItems;
    uint256 public nextItemId = 1;
    uint16 public marketplaceFee = 500; // 5%

    uint128 public constant MIN_CHARACTER_PRICE = 50000 * 10**18;
    uint128 public constant MAX_CHARACTER_PRICE = 50000000 * 10**18;

    // ══════════════════════════════════════════════════════════════════════
    //                          GAME UPGRADES
    // ══════════════════════════════════════════════════════════════════════

    struct GameUpgrade {
        uint128 price;
        uint8 upgradeType;
        uint8 upgradeValue;
        bool isActive;
    }

    mapping(uint256 => GameUpgrade) public gameUpgrades;
    mapping(address => mapping(uint256 => uint8)) public userUpgradeLevels;
    uint8 public constant MAX_UPGRADE_ID = 10;

    // ══════════════════════════════════════════════════════════════════════
    //                 SESSION REWARDS (FPS, MMO, Runner, vb.)
    // ══════════════════════════════════════════════════════════════════════

    mapping(bytes32 => bool) public usedSessionClaims;
    uint256 public rewardPoolBalance;
    uint256 public maxRewardPerSession = 100_000 * 10**18;
    uint256 public maxDailyRewardPerUser = 500_000 * 10**18;
    mapping(address => mapping(uint256 => uint256)) public dailyRewardsClaimed; // user => day => total

    // ══════════════════════════════════════════════════════════════════════
    //                            EVENTS
    // ══════════════════════════════════════════════════════════════════════

    // PvP Games
    event GameCreated(uint256 indexed gameId, address indexed creator, uint256 stakeAmount);
    event GameJoined(uint256 indexed gameId, address indexed player);
    event GameCompleted(uint256 indexed gameId, address indexed winner, uint256 prize);
    event GameCancelled(uint256 indexed gameId);

    // Battles
    event BattleCreated(uint256 indexed battleId, address indexed initiator, uint256 stakeAmount);
    event BattleJoined(uint256 indexed battleId, address indexed opponent);
    event BattleCompleted(uint256 indexed battleId, address indexed winner, uint256 prize);
    event BattleCancelled(uint256 indexed battleId);

    // Quick Match
    event QueueJoined(uint256 indexed queueId, address indexed player, uint256 stake);
    event QueueCancelled(uint256 indexed queueId);
    event QuickMatchCompleted(uint256 indexed gameId, address indexed player1, address indexed player2, uint256 stake);

    // Marketplace
    event MarketplaceItemListed(uint256 indexed itemId, address indexed seller, uint256 characterId, uint256 amount);
    event MarketplaceItemSold(uint256 indexed itemId, address indexed buyer, uint256 amount);
    event MarketplaceItemCancelled(uint256 indexed itemId);

    // Upgrades
    event UpgradePurchased(address indexed user, uint256 indexed upgradeId, uint256 level, uint256 price);

    // Session Rewards
    event SessionRewardClaimed(address indexed player, bytes32 indexed sessionId, uint256 amount);
    event RewardPoolDeposited(address indexed depositor, uint256 amount);

    // Admin
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event Burn(address indexed from, uint256 amount, string reason);

    // ══════════════════════════════════════════════════════════════════════
    //                          CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════════

    constructor(address _coffyToken, address _trustedSigner) {
        require(_coffyToken != address(0), "!token");
        require(_trustedSigner != address(0), "!signer");

        coffyToken = ICoffyTokenV2(_coffyToken);
        coffyERC20 = IERC20(_coffyToken);
        trustedSigner = _trustedSigner;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        for (uint8 i = 1; i <= 10; i++) {
            gameUpgrades[i] = GameUpgrade({
                price: uint128(50000 * 10**18 * i),
                upgradeType: i,
                upgradeValue: uint8(10 + i * 2),
                isActive: true
            });
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //                       PVP GAME FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    function createGame(uint128 _stakeAmount) external nonReentrant whenNotPaused {
        require(_stakeAmount > 0, "!stake");
        require(coffyToken.balanceOf(msg.sender) >= _stakeAmount, "!bal");

        coffyERC20.transferFrom(msg.sender, address(this), _stakeAmount);
        totalLockedStakes += _stakeAmount;

        uint256 gameId = nextGameId++;
        games[gameId] = Game({
            player1: msg.sender,
            player2: address(0),
            stakePerPlayer: _stakeAmount,
            totalStaked: _stakeAmount,
            createdAt: uint64(block.timestamp),
            status: 0,
            winner: address(0)
        });

        emit GameCreated(gameId, msg.sender, _stakeAmount);
    }

    function joinGame(uint256 _gameId) external nonReentrant whenNotPaused {
        Game storage game = games[_gameId];
        require(game.status == 0, "!pending");
        require(game.player2 == address(0), "!full");
        require(game.player1 != msg.sender, "!self");

        uint128 requiredStake = game.stakePerPlayer;
        require(coffyToken.balanceOf(msg.sender) >= requiredStake, "!bal");

        coffyERC20.transferFrom(msg.sender, address(this), requiredStake);
        totalLockedStakes += requiredStake;

        game.player2 = msg.sender;
        game.totalStaked += requiredStake;
        game.status = 1;

        emit GameJoined(_gameId, msg.sender);
    }

    function cancelGame(uint256 _gameId) external nonReentrant {
        Game storage game = games[_gameId];
        require(game.status == 0, "!pending");
        require(game.player1 == msg.sender, "!creator");

        game.status = 3;
        totalLockedStakes -= game.stakePerPlayer;

        coffyERC20.transfer(msg.sender, game.stakePerPlayer);

        emit GameCancelled(_gameId);
    }

    /**
     * @dev Backend imzası: keccak256("GAME_WIN", gameId, winner, chainId, contract)
     */
    function claimGameWin(uint256 _gameId, bytes calldata _signature) external nonReentrant {
        Game storage game = games[_gameId];
        require(game.status == 1, "!active");
        require(msg.sender == game.player1 || msg.sender == game.player2, "!participant");
        require(!hasClaimedGame[_gameId][msg.sender], "!claimed");

        _verifySignature("GAME_WIN", _gameId, msg.sender, _signature);

        game.status = 2;
        game.winner = msg.sender;
        hasClaimedGame[_gameId][msg.sender] = true;
        totalLockedStakes -= game.totalStaked;

        _distributePrize(game.totalStaked, msg.sender, gameFee);

        emit GameCompleted(_gameId, msg.sender, game.totalStaked);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                       BATTLE FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    function createBattle(uint128 _stakeAmount) external nonReentrant whenNotPaused {
        require(_stakeAmount > 0, "!stake");
        require(coffyToken.balanceOf(msg.sender) >= _stakeAmount, "!bal");

        coffyERC20.transferFrom(msg.sender, address(this), _stakeAmount);
        totalLockedStakes += _stakeAmount;

        uint256 battleId = nextBattleId++;
        battles[battleId] = Battle({
            initiator: msg.sender,
            opponent: address(0),
            stakeAmount: _stakeAmount,
            createdAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + battleExpiration),
            status: 0,
            winner: address(0)
        });

        emit BattleCreated(battleId, msg.sender, _stakeAmount);
    }

    function joinBattle(uint256 _battleId) external nonReentrant whenNotPaused {
        Battle storage battle = battles[_battleId];
        require(battle.status == 0, "!available");
        require(battle.initiator != msg.sender, "!own");
        require(block.timestamp < battle.expiresAt, "expired");
        require(coffyToken.balanceOf(msg.sender) >= battle.stakeAmount, "!bal");

        coffyERC20.transferFrom(msg.sender, address(this), battle.stakeAmount);
        totalLockedStakes += battle.stakeAmount;

        battle.opponent = msg.sender;
        battle.status = 1;

        emit BattleJoined(_battleId, msg.sender);
    }

    function cancelBattle(uint256 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == 0, "!pending");
        require(battle.initiator == msg.sender, "!creator");

        battle.status = 3;
        totalLockedStakes -= battle.stakeAmount;

        coffyERC20.transfer(msg.sender, battle.stakeAmount);

        emit BattleCancelled(_battleId);
    }

    function cancelExpiredBattle(uint256 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == 0, "!pending");
        require(block.timestamp >= battle.expiresAt, "!expired");

        battle.status = 3;
        totalLockedStakes -= battle.stakeAmount;

        coffyERC20.transfer(battle.initiator, battle.stakeAmount);

        emit BattleCancelled(_battleId);
    }

    /**
     * @dev Backend imzası: keccak256("BATTLE_WIN", battleId, winner, chainId, contract)
     */
    function claimBattleWin(uint256 _battleId, bytes calldata _signature) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == 1, "!active");
        require(msg.sender == battle.initiator || msg.sender == battle.opponent, "!participant");
        require(!hasClaimedBattle[_battleId][msg.sender], "!claimed");

        _verifySignature("BATTLE_WIN", _battleId, msg.sender, _signature);

        battle.status = 2;
        battle.winner = msg.sender;
        hasClaimedBattle[_battleId][msg.sender] = true;

        uint256 totalPrize = uint256(battle.stakeAmount) * 2;
        totalLockedStakes -= totalPrize;

        _distributePrize(totalPrize, msg.sender, battleFee);

        emit BattleCompleted(_battleId, msg.sender, totalPrize);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                      QUICK MATCH FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @dev Kuyruğa gir — eşleşme backend tarafından yapılır
     *      Backend eşleştirince createGame + joinGame otomatik oluşturulur
     */
    function joinQuickMatch(uint128 _stake) external nonReentrant whenNotPaused {
        require(_stake > 0, "!stake");
        require(coffyToken.balanceOf(msg.sender) >= _stake, "!bal");

        coffyERC20.transferFrom(msg.sender, address(this), _stake);
        totalLockedStakes += _stake;

        uint256 queueId = nextQueueId++;
        matchQueue[queueId] = QueueEntry({
            player: msg.sender,
            stake: _stake,
            queuedAt: uint64(block.timestamp),
            active: true
        });

        emit QueueJoined(queueId, msg.sender, _stake);
    }

    /**
     * @dev Kuyruktan çıkart — sadece oyuncu iptal edebilir
     */
    function cancelQuickMatch(uint256 _queueId) external nonReentrant {
        QueueEntry storage entry = matchQueue[_queueId];
        require(entry.active, "!active");
        require(entry.player == msg.sender, "!owner");

        entry.active = false;
        totalLockedStakes -= entry.stake;

        coffyERC20.transfer(msg.sender, entry.stake);

        emit QueueCancelled(_queueId);
    }

    /**
     * @dev Süresi dolmuş kuyruk girişini iptal — herkes çağırabilir
     */
    function cancelExpiredQueue(uint256 _queueId) external nonReentrant {
        QueueEntry storage entry = matchQueue[_queueId];
        require(entry.active, "!active");
        require(block.timestamp >= entry.queuedAt + queueExpiration, "!expired");

        entry.active = false;
        totalLockedStakes -= entry.stake;

        coffyERC20.transfer(entry.player, entry.stake);

        emit QueueCancelled(_queueId);
    }

    /**
     * @dev Backend iki kuyruktaki oyuncuyu eşleştirir → otomatik PvP oyun oluşturur
     *      Backend imzası: keccak256("QUICK_MATCH", queueId1, queueId2, chainId, contract)
     */
    function executeQuickMatch(
        uint256 _queueId1,
        uint256 _queueId2,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        QueueEntry storage e1 = matchQueue[_queueId1];
        QueueEntry storage e2 = matchQueue[_queueId2];
        require(e1.active && e2.active, "!active");
        require(e1.player != e2.player, "!same");
        require(e1.stake == e2.stake, "!stake");

        // İmza: backend eşleşmeyi onaylıyor
        bytes32 messageHash = keccak256(abi.encodePacked(
            "QUICK_MATCH",
            _queueId1,
            _queueId2,
            block.chainid,
            address(this)
        ));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        require(ethSignedHash.recover(_signature) == trustedSigner, "!signature");

        // Queue girişlerini kapat
        e1.active = false;
        e2.active = false;

        // Queue stake'leri zaten totalLockedStakes'e eklenmişti
        // Yeni oyun oluştur — stake'ler zaten kontratda
        uint256 gameId = nextGameId++;
        uint128 stakePerPlayer = e1.stake;
        games[gameId] = Game({
            player1: e1.player,
            player2: e2.player,
            stakePerPlayer: stakePerPlayer,
            totalStaked: stakePerPlayer * 2,
            createdAt: uint64(block.timestamp),
            status: 1, // Doğrudan Active (iki oyuncu da stake yatırmış)
            winner: address(0)
        });

        emit QuickMatchCompleted(gameId, e1.player, e2.player, stakePerPlayer);
        emit GameCreated(gameId, e1.player, stakePerPlayer);
        emit GameJoined(gameId, e2.player);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                    MARKETPLACE FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    function listMarketplaceItem(
        uint8 _characterId,
        uint128 _amount,
        uint128 _pricePerUnit
    ) external nonReentrant whenNotPaused {
        require(_amount > 0, "!amount");
        require(_pricePerUnit >= MIN_CHARACTER_PRICE && _pricePerUnit <= MAX_CHARACTER_PRICE, "!price");
        require(coffyToken.getUserCharacterBalance(msg.sender, _characterId) >= _amount, "!charBal");

        // Karakterleri kontrata kilitle (satıcı → kontrat)
        coffyToken.transferCharacterForModule(msg.sender, address(this), _characterId, _amount);

        uint256 itemId = nextItemId++;
        marketplaceItems[itemId] = MarketplaceItem({
            seller: msg.sender,
            characterId: _characterId,
            amount: _amount,
            pricePerUnit: _pricePerUnit,
            isActive: true
        });

        emit MarketplaceItemListed(itemId, msg.sender, _characterId, _amount);
    }

    function buyMarketplaceItem(uint256 _itemId, uint128 _amount) external nonReentrant whenNotPaused {
        MarketplaceItem storage item = marketplaceItems[_itemId];
        require(item.isActive, "!active");
        require(_amount > 0 && _amount <= item.amount, "!amount");
        require(msg.sender != item.seller, "!own");

        uint256 totalCost = uint256(item.pricePerUnit) * _amount;
        require(coffyToken.balanceOf(msg.sender) >= totalCost, "!bal");

        item.amount -= _amount;
        if (item.amount == 0) item.isActive = false;

        // Alıcıdan toplam tutarı kontrata çek
        coffyERC20.transferFrom(msg.sender, address(this), totalCost);

        // Fee hesapla
        uint256 fee = (totalCost * marketplaceFee) / 10000;
        uint256 sellerAmount = totalCost - fee;

        // Satıcıya net ödeme
        coffyERC20.transfer(item.seller, sellerAmount);

        // Fee dağılımı
        if (fee > 0) {
            uint256 burnAmount = (fee * 2000) / 10000;
            uint256 treasuryAmount = fee - burnAmount;

            coffyERC20.transfer(DEAD, burnAmount);
            coffyERC20.transfer(coffyToken.treasury(), treasuryAmount);

            emit Burn(msg.sender, burnAmount, "marketplace_fee");
        }

        // Kilitli karakteri alıcıya transfer et (kontrat → alıcı)
        coffyToken.transferCharacterForModule(address(this), msg.sender, item.characterId, _amount);

        emit MarketplaceItemSold(_itemId, msg.sender, _amount);
    }

    function cancelMarketplaceItem(uint256 _itemId) external nonReentrant {
        MarketplaceItem storage item = marketplaceItems[_itemId];
        require(item.isActive, "!active");
        require(item.seller == msg.sender, "!seller");

        uint128 lockedAmount = item.amount;
        item.isActive = false;

        // Kilitli karakterleri satıcıya iade et (kontrat → satıcı)
        coffyToken.transferCharacterForModule(address(this), msg.sender, item.characterId, lockedAmount);

        emit MarketplaceItemCancelled(_itemId);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                    GAME UPGRADE FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    function purchaseUpgrade(uint256 _upgradeId) external nonReentrant whenNotPaused {
        require(_upgradeId >= 1 && _upgradeId <= MAX_UPGRADE_ID, "!id");
        GameUpgrade storage upgrade = gameUpgrades[_upgradeId];
        require(upgrade.isActive, "!active");

        uint8 currentLevel = userUpgradeLevels[msg.sender][_upgradeId];
        require(currentLevel < 5, "!maxLv");

        uint256 price = uint256(upgrade.price) * (currentLevel + 1);
        require(coffyToken.balanceOf(msg.sender) >= price, "!bal");

        // Kullanıcıdan çek ve yak
        coffyERC20.transferFrom(msg.sender, DEAD, price);

        userUpgradeLevels[msg.sender][_upgradeId] = currentLevel + 1;

        emit UpgradePurchased(msg.sender, _upgradeId, currentLevel + 1, price);
        emit Burn(msg.sender, price, "upgrade");
    }

    // ══════════════════════════════════════════════════════════════════════
    //             SESSION REWARDS (FPS, MMO, Runner, vb.)
    // ══════════════════════════════════════════════════════════════════════

    function depositRewardPool(uint256 _amount) external nonReentrant {
        require(_amount > 0, "!amount");
        coffyERC20.transferFrom(msg.sender, address(this), _amount);
        rewardPoolBalance += _amount;

        emit RewardPoolDeposited(msg.sender, _amount);
    }

    /**
     * @dev Backend imzası: keccak256("SESSION_REWARD", sessionId, player, amount, chainId, contract)
     */
    function claimSessionReward(
        bytes32 _sessionId,
        uint256 _amount,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        require(!usedSessionClaims[_sessionId], "!used");
        require(_amount > 0, "!amount");
        require(_amount <= maxRewardPerSession, "!maxSession");
        require(rewardPoolBalance >= _amount, "!pool");

        // Günlük limit kontrolü (Sybil koruması)
        uint256 today = block.timestamp / 1 days;
        require(dailyRewardsClaimed[msg.sender][today] + _amount <= maxDailyRewardPerUser, "!dailyLimit");

        // İmza doğrula
        bytes32 messageHash = keccak256(abi.encodePacked(
            "SESSION_REWARD",
            _sessionId,
            msg.sender,
            _amount,
            block.chainid,
            address(this)
        ));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        require(ethSignedHash.recover(_signature) == trustedSigner, "!signature");

        usedSessionClaims[_sessionId] = true;
        dailyRewardsClaimed[msg.sender][today] += _amount;
        rewardPoolBalance -= _amount;

        coffyERC20.transfer(msg.sender, _amount);

        emit SessionRewardClaimed(msg.sender, _sessionId, _amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                     INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    function _distributePrize(uint256 _totalPrize, address _winner, uint16 _feeRate) internal {
        uint256 fee = (_totalPrize * _feeRate) / 10000;
        uint256 winnerPrize = _totalPrize - fee;

        coffyERC20.transfer(_winner, winnerPrize);

        if (fee > 0) {
            uint256 burnAmount = (fee * 2000) / 10000;
            uint256 treasuryAmount = fee - burnAmount;

            coffyERC20.transfer(DEAD, burnAmount);
            coffyERC20.transfer(coffyToken.treasury(), treasuryAmount);

            emit Burn(address(this), burnAmount, "game_fee");
        }
    }

    function _verifySignature(string memory _prefix, uint256 _id, address _claimer, bytes calldata _signature) internal view {
        bytes32 messageHash = keccak256(abi.encodePacked(
            _prefix,
            _id,
            _claimer,
            block.chainid,
            address(this)
        ));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        require(ethSignedHash.recover(_signature) == trustedSigner, "!signature");
    }

    // ══════════════════════════════════════════════════════════════════════
    //                      ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    function setTrustedSigner(address _newSigner) external onlyRole(ADMIN_ROLE) {
        require(_newSigner != address(0), "!address");
        address oldSigner = trustedSigner;
        trustedSigner = _newSigner;
        emit SignerUpdated(oldSigner, _newSigner);
    }

    function setGameFee(uint16 _fee) external onlyRole(ADMIN_ROLE) {
        require(_fee <= 1000, "!max10%");
        gameFee = _fee;
    }

    function setBattleFee(uint16 _fee) external onlyRole(ADMIN_ROLE) {
        require(_fee <= 1000, "!max10%");
        battleFee = _fee;
    }

    function setMarketplaceFee(uint16 _fee) external onlyRole(ADMIN_ROLE) {
        require(_fee <= 1000, "!max10%");
        marketplaceFee = _fee;
    }

    function setBattleExpiration(uint32 _expiration) external onlyRole(ADMIN_ROLE) {
        require(_expiration >= 1 hours && _expiration <= 7 days, "!range");
        battleExpiration = _expiration;
    }

    function setQueueExpiration(uint32 _expiration) external onlyRole(ADMIN_ROLE) {
        require(_expiration >= 1 minutes && _expiration <= 1 hours, "!range");
        queueExpiration = _expiration;
    }

    function setMaxRewardPerSession(uint256 _max) external onlyRole(ADMIN_ROLE) {
        maxRewardPerSession = _max;
    }

    function setMaxDailyRewardPerUser(uint256 _max) external onlyRole(ADMIN_ROLE) {
        maxDailyRewardPerUser = _max;
    }

    function setGameUpgrade(
        uint256 _upgradeId,
        uint128 _price,
        uint8 _upgradeType,
        uint8 _upgradeValue,
        bool _isActive
    ) external onlyRole(ADMIN_ROLE) {
        require(_upgradeId >= 1 && _upgradeId <= MAX_UPGRADE_ID, "!id");
        gameUpgrades[_upgradeId] = GameUpgrade({
            price: _price,
            upgradeType: _upgradeType,
            upgradeValue: _upgradeValue,
            isActive: _isActive
        });
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function emergencyCancelGame(uint256 _gameId) external onlyRole(ADMIN_ROLE) {
        Game storage game = games[_gameId];
        require(game.status == 0 || game.status == 1, "!cancellable");

        uint8 oldStatus = game.status;
        game.status = 3;

        coffyERC20.transfer(game.player1, game.stakePerPlayer);
        totalLockedStakes -= game.stakePerPlayer;
        if (oldStatus == 1 && game.player2 != address(0)) {
            coffyERC20.transfer(game.player2, game.stakePerPlayer);
            totalLockedStakes -= game.stakePerPlayer;
        }

        emit GameCancelled(_gameId);
    }

    function emergencyCancelBattle(uint256 _battleId) external onlyRole(ADMIN_ROLE) {
        Battle storage battle = battles[_battleId];
        require(battle.status == 0 || battle.status == 1, "!cancellable");

        uint8 oldStatus = battle.status;
        battle.status = 3;

        coffyERC20.transfer(battle.initiator, battle.stakeAmount);
        totalLockedStakes -= battle.stakeAmount;
        if (oldStatus == 1 && battle.opponent != address(0)) {
            coffyERC20.transfer(battle.opponent, battle.stakeAmount);
            totalLockedStakes -= battle.stakeAmount;
        }

        emit BattleCancelled(_battleId);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                       VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    function getGameInfo(uint256 _gameId) external view returns (
        address player1, address player2,
        uint256 stakePerPlayer, uint256 totalStaked,
        uint256 createdAt, uint8 status, address winner
    ) {
        Game memory g = games[_gameId];
        return (g.player1, g.player2, g.stakePerPlayer, g.totalStaked, g.createdAt, g.status, g.winner);
    }

    function getBattleInfo(uint256 _battleId) external view returns (
        address initiator, address opponent,
        uint256 stakeAmount, uint256 createdAt,
        uint256 expiresAt, uint8 status, address winner
    ) {
        Battle memory b = battles[_battleId];
        return (b.initiator, b.opponent, b.stakeAmount, b.createdAt, b.expiresAt, b.status, b.winner);
    }

    function getQueueEntry(uint256 _queueId) external view returns (
        address player, uint256 stake, uint256 queuedAt, bool active
    ) {
        QueueEntry memory e = matchQueue[_queueId];
        return (e.player, e.stake, e.queuedAt, e.active);
    }

    function getMarketplaceItem(uint256 _itemId) external view returns (
        address seller, uint8 characterId,
        uint128 amount, uint128 pricePerUnit, bool isActive
    ) {
        MarketplaceItem memory item = marketplaceItems[_itemId];
        return (item.seller, item.characterId, item.amount, item.pricePerUnit, item.isActive);
    }

    function getUserUpgradeLevel(address _user, uint256 _upgradeId) external view returns (uint8) {
        return userUpgradeLevels[_user][_upgradeId];
    }

    function getUserDailyRewards(address _user) external view returns (uint256 claimed, uint256 remaining) {
        uint256 today = block.timestamp / 1 days;
        claimed = dailyRewardsClaimed[_user][today];
        remaining = maxDailyRewardPerUser > claimed ? maxDailyRewardPerUser - claimed : 0;
    }

    /**
     * @dev Kontrat bakiye tutarlılığı kontrolü
     *      availableBalance = totalBalance - lockedStakes - rewardPool
     */
    function getBalanceBreakdown() external view returns (
        uint256 totalBalance,
        uint256 lockedInStakes,
        uint256 lockedInRewardPool,
        uint256 availableBalance
    ) {
        totalBalance = coffyToken.balanceOf(address(this));
        lockedInStakes = totalLockedStakes;
        lockedInRewardPool = rewardPoolBalance;
        uint256 locked = lockedInStakes + lockedInRewardPool;
        availableBalance = totalBalance > locked ? totalBalance - locked : 0;
    }

    function verifyGameWinSignature(
        uint256 _gameId, address _winner, bytes calldata _signature
    ) external view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked("GAME_WIN", _gameId, _winner, block.chainid, address(this)));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        return ethSignedHash.recover(_signature) == trustedSigner;
    }

    function verifySessionSignature(
        bytes32 _sessionId, address _player, uint256 _amount, bytes calldata _signature
    ) external view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked("SESSION_REWARD", _sessionId, _player, _amount, block.chainid, address(this)));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        return ethSignedHash.recover(_signature) == trustedSigner;
    }
}
