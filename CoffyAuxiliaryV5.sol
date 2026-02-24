// SPDX-License-Identifier: MIT
// Version: V5 — setCoffyToken eklendi
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

contract CoffyAuxiliaryV5 is AccessControl, ReentrancyGuard, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    ICoffyTokenV2 public coffyToken;
    IERC20 public coffyERC20;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public trustedSigner;
    uint256 public totalLockedStakes;

    
    
    

    struct PlayerStats {
        uint64 totalGames;
        uint64 wins;
        uint64 draws;
        uint64 losses;
        uint128 totalWinnings;   
        uint128 totalStaked;     
    }

    mapping(address => PlayerStats) public playerStats;

    
    
    

    struct Game {
        address player1;
        address player2;
        uint128 stakePerPlayer;
        uint128 totalStaked;
        uint64 createdAt;
        uint8 status; 
        address winner;
    }

    mapping(uint256 => Game) public games;
    mapping(uint256 => mapping(address => bool)) public hasClaimedGame;
    uint256 public nextGameId = 1;
    uint16 public gameFee = 500; 

    
    
    

    struct Battle {
        address initiator;
        address opponent;
        uint128 stakeAmount;
        uint64 createdAt;
        uint64 expiresAt;
        uint8 status; 
        address winner;
    }

    mapping(uint256 => Battle) public battles;
    mapping(uint256 => mapping(address => bool)) public hasClaimedBattle;
    uint256 public nextBattleId = 1;
    uint16 public battleFee = 500; 
    uint32 public battleExpiration = 24 hours;

    
    
    

    struct QueueEntry {
        address player;
        uint128 stake;
        uint64 queuedAt;
        bool active;
    }

    mapping(uint256 => QueueEntry) public matchQueue;
    uint256 public nextQueueId = 1;
    uint32 public queueExpiration = 10 minutes;

    
    
    

    struct MarketplaceItem {
        address seller;
        uint8 characterId;
        uint128 amount;
        uint128 pricePerUnit;
        bool isActive;
    }

    mapping(uint256 => MarketplaceItem) public marketplaceItems;
    uint256 public nextItemId = 1;
    uint16 public marketplaceFee = 500; 

    uint128 public constant MIN_CHARACTER_PRICE = 50000 * 10**18;
    uint128 public constant MAX_CHARACTER_PRICE = 50000000 * 10**18;

    
    
    

    struct GameUpgrade {
        uint128 price;
        uint8 upgradeType;
        uint8 upgradeValue;
        bool isActive;
    }

    mapping(uint256 => GameUpgrade) public gameUpgrades;
    mapping(address => mapping(uint256 => uint8)) public userUpgradeLevels;
    uint8 public constant MAX_UPGRADE_ID = 10;

    
    
    

    mapping(bytes32 => bool) public usedSessionClaims;
    uint256 public rewardPoolBalance;
    uint256 public maxRewardPerSession = 100_000 * 10**18;
    uint256 public maxDailyRewardPerUser = 500_000 * 10**18;
    mapping(address => mapping(uint256 => uint256)) public dailyRewardsClaimed;

    
    
    

    
    
    bool public characterBonusEnabled = true;

    
    uint32 public gameAbandonTimeout = 2 hours;

    
    
    

    event GameCreated(uint256 indexed gameId, address indexed creator, uint256 stakeAmount);
    event GameJoined(uint256 indexed gameId, address indexed player);
    event GameCompleted(uint256 indexed gameId, address indexed winner, uint256 prize);
    event GameCancelled(uint256 indexed gameId);
    event GameDraw(uint256 indexed gameId, address indexed player, uint256 refundAmount);        

    event BattleCreated(uint256 indexed battleId, address indexed initiator, uint256 stakeAmount);
    event BattleJoined(uint256 indexed battleId, address indexed opponent);
    event BattleCompleted(uint256 indexed battleId, address indexed winner, uint256 prize);
    event BattleCancelled(uint256 indexed battleId);
    event BattleDraw(uint256 indexed battleId, address indexed player, uint256 refundAmount);    

    event QueueJoined(uint256 indexed queueId, address indexed player, uint256 stake);
    event QueueCancelled(uint256 indexed queueId);
    event QuickMatchCompleted(uint256 indexed gameId, address indexed player1, address indexed player2, uint256 stake);

    event MarketplaceItemListed(uint256 indexed itemId, address indexed seller, uint256 characterId, uint256 amount);
    event MarketplaceItemSold(uint256 indexed itemId, address indexed buyer, uint256 amount);
    event MarketplaceItemCancelled(uint256 indexed itemId);

    event UpgradePurchased(address indexed user, uint256 indexed upgradeId, uint256 level, uint256 price);

    event SessionRewardClaimed(address indexed player, bytes32 indexed sessionId, uint256 amount);
    event RewardPoolDeposited(address indexed depositor, uint256 amount);

    event CharacterBonusPaid(address indexed winner, uint256 characterId, uint256 bonusAmount); 
    event PlayerStatsUpdated(address indexed player, uint64 totalGames, uint64 wins);           

    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event Burn(address indexed from, uint256 amount, string reason);

    
    
    

    constructor(address _coffyToken, address _trustedSigner) {
        require(_coffyToken != address(0));
        require(_trustedSigner != address(0));

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

    
    
    

    function createGame(uint128 _stakeAmount) external nonReentrant whenNotPaused {
        require(_stakeAmount > 0);
        require(coffyToken.balanceOf(msg.sender) >= _stakeAmount);

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
        require(game.status == 0);
        require(game.player2 == address(0));
        require(game.player1 != msg.sender);

        uint128 requiredStake = game.stakePerPlayer;
        require(coffyToken.balanceOf(msg.sender) >= requiredStake);

        coffyERC20.transferFrom(msg.sender, address(this), requiredStake);
        totalLockedStakes += requiredStake;

        game.player2 = msg.sender;
        game.totalStaked += requiredStake;
        game.status = 1;

        
        playerStats[game.player1].totalStaked += requiredStake;
        playerStats[game.player2].totalStaked += requiredStake;

        emit GameJoined(_gameId, msg.sender);
    }

    function cancelGame(uint256 _gameId) external nonReentrant {
        Game storage game = games[_gameId];
        require(game.status == 0);
        require(game.player1 == msg.sender);

        game.status = 3;
        totalLockedStakes -= game.stakePerPlayer;
        coffyERC20.transfer(msg.sender, game.stakePerPlayer);

        emit GameCancelled(_gameId);
    }

    
    function claimGameWin(uint256 _gameId, bytes calldata _signature) external nonReentrant {
        Game storage game = games[_gameId];
        require(game.status == 1);
        require(msg.sender == game.player1 || msg.sender == game.player2);
        require(!hasClaimedGame[_gameId][msg.sender]);

        _verifySignature("GAME_WIN", _gameId, msg.sender, _signature);

        game.status = 2;
        game.winner = msg.sender;
        hasClaimedGame[_gameId][msg.sender] = true;
        totalLockedStakes -= game.totalStaked;

        
        uint256 bonus = _payCharacterBonus(msg.sender, game.totalStaked);

        _distributePrize(game.totalStaked, msg.sender, gameFee);

        
        address loser = msg.sender == game.player1 ? game.player2 : game.player1;
        _updateStats(msg.sender, loser, game.totalStaked - (game.totalStaked * gameFee / 10000) + bonus, false);

        emit GameCompleted(_gameId, msg.sender, game.totalStaked);
    }

    
    function claimGameDraw(uint256 _gameId, bytes calldata _signature) external nonReentrant {
        Game storage game = games[_gameId];
        require(game.status == 1);
        require(msg.sender == game.player1 || msg.sender == game.player2);
        require(!hasClaimedGame[_gameId][msg.sender]);

        _verifySignature("GAME_DRAW", _gameId, msg.sender, _signature);

        hasClaimedGame[_gameId][msg.sender] = true;
        totalLockedStakes -= game.stakePerPlayer;

        
        coffyERC20.transfer(msg.sender, game.stakePerPlayer);

        
        address other = msg.sender == game.player1 ? game.player2 : game.player1;
        if (hasClaimedGame[_gameId][other]) {
            game.status = 2;
            game.winner = address(0);
        }

        
        playerStats[msg.sender].totalGames += 1;
        playerStats[msg.sender].draws += 1;
        emit PlayerStatsUpdated(msg.sender, playerStats[msg.sender].totalGames, playerStats[msg.sender].wins);

        emit GameDraw(_gameId, msg.sender, game.stakePerPlayer);
    }

    
    function cancelAbandonedGame(uint256 _gameId) external nonReentrant {
        Game storage game = games[_gameId];
        require(game.status == 1);
        require(block.timestamp >= game.createdAt + gameAbandonTimeout);

        game.status = 3;
        totalLockedStakes -= game.totalStaked;

        coffyERC20.transfer(game.player1, game.stakePerPlayer);
        coffyERC20.transfer(game.player2, game.stakePerPlayer);

        emit GameCancelled(_gameId);
    }

    
    
    

    function createBattle(uint128 _stakeAmount) external nonReentrant whenNotPaused {
        require(_stakeAmount > 0);
        require(coffyToken.balanceOf(msg.sender) >= _stakeAmount);

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
        require(battle.status == 0);
        require(battle.initiator != msg.sender);
        require(block.timestamp < battle.expiresAt);
        require(coffyToken.balanceOf(msg.sender) >= battle.stakeAmount);

        coffyERC20.transferFrom(msg.sender, address(this), battle.stakeAmount);
        totalLockedStakes += battle.stakeAmount;

        battle.opponent = msg.sender;
        battle.status = 1;

        emit BattleJoined(_battleId, msg.sender);
    }

    function cancelBattle(uint256 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == 0);
        require(battle.initiator == msg.sender);

        battle.status = 3;
        totalLockedStakes -= battle.stakeAmount;
        coffyERC20.transfer(msg.sender, battle.stakeAmount);

        emit BattleCancelled(_battleId);
    }

    function cancelExpiredBattle(uint256 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == 0);
        require(block.timestamp >= battle.expiresAt);

        battle.status = 3;
        totalLockedStakes -= battle.stakeAmount;
        coffyERC20.transfer(battle.initiator, battle.stakeAmount);

        emit BattleCancelled(_battleId);
    }

    
    function claimBattleWin(uint256 _battleId, bytes calldata _signature) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == 1);
        require(msg.sender == battle.initiator || msg.sender == battle.opponent);
        require(!hasClaimedBattle[_battleId][msg.sender]);

        _verifySignature("BATTLE_WIN", _battleId, msg.sender, _signature);

        battle.status = 2;
        battle.winner = msg.sender;
        hasClaimedBattle[_battleId][msg.sender] = true;

        uint256 totalPrize = uint256(battle.stakeAmount) * 2;
        totalLockedStakes -= totalPrize;

        
        uint256 bonus = _payCharacterBonus(msg.sender, totalPrize);

        _distributePrize(totalPrize, msg.sender, battleFee);

        
        address loser = msg.sender == battle.initiator ? battle.opponent : battle.initiator;
        _updateStats(msg.sender, loser, totalPrize - (totalPrize * battleFee / 10000) + bonus, false);

        emit BattleCompleted(_battleId, msg.sender, totalPrize);
    }

    
    function claimBattleDraw(uint256 _battleId, bytes calldata _signature) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == 1);
        require(msg.sender == battle.initiator || msg.sender == battle.opponent);
        require(!hasClaimedBattle[_battleId][msg.sender]);

        _verifySignature("BATTLE_DRAW", _battleId, msg.sender, _signature);

        hasClaimedBattle[_battleId][msg.sender] = true;
        totalLockedStakes -= battle.stakeAmount;

        coffyERC20.transfer(msg.sender, battle.stakeAmount);

        address other = msg.sender == battle.initiator ? battle.opponent : battle.initiator;
        if (hasClaimedBattle[_battleId][other]) {
            battle.status = 2;
            battle.winner = address(0);
        }

        playerStats[msg.sender].totalGames += 1;
        playerStats[msg.sender].draws += 1;
        emit PlayerStatsUpdated(msg.sender, playerStats[msg.sender].totalGames, playerStats[msg.sender].wins);

        emit BattleDraw(_battleId, msg.sender, battle.stakeAmount);
    }

    
    function cancelAbandonedBattle(uint256 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == 1);
        require(block.timestamp >= battle.createdAt + gameAbandonTimeout);

        battle.status = 3;
        uint256 total = uint256(battle.stakeAmount) * 2;
        totalLockedStakes -= total;

        coffyERC20.transfer(battle.initiator, battle.stakeAmount);
        coffyERC20.transfer(battle.opponent, battle.stakeAmount);

        emit BattleCancelled(_battleId);
    }

    
    
    

    function joinQuickMatch(uint128 _stake) external nonReentrant whenNotPaused {
        require(_stake > 0);
        require(coffyToken.balanceOf(msg.sender) >= _stake);

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

    function cancelQuickMatch(uint256 _queueId) external nonReentrant {
        QueueEntry storage entry = matchQueue[_queueId];
        require(entry.active);
        require(entry.player == msg.sender);

        entry.active = false;
        totalLockedStakes -= entry.stake;
        coffyERC20.transfer(msg.sender, entry.stake);

        emit QueueCancelled(_queueId);
    }

    function cancelExpiredQueue(uint256 _queueId) external nonReentrant {
        QueueEntry storage entry = matchQueue[_queueId];
        require(entry.active);
        require(block.timestamp >= entry.queuedAt + queueExpiration);

        entry.active = false;
        totalLockedStakes -= entry.stake;
        coffyERC20.transfer(entry.player, entry.stake);

        emit QueueCancelled(_queueId);
    }

    
    function executeQuickMatch(
        uint256 _queueId1,
        uint256 _queueId2,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        QueueEntry storage e1 = matchQueue[_queueId1];
        QueueEntry storage e2 = matchQueue[_queueId2];
        require(e1.active && e2.active);
        require(e1.player != e2.player);
        require(e1.stake == e2.stake);

        bytes32 messageHash = keccak256(abi.encodePacked(
            "QUICK_MATCH",
            _queueId1,
            _queueId2,
            block.chainid,
            address(this)
        ));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        require(ethSignedHash.recover(_signature) == trustedSigner);

        e1.active = false;
        e2.active = false;

        uint256 gameId = nextGameId++;
        uint128 stakePerPlayer = e1.stake;
        games[gameId] = Game({
            player1: e1.player,
            player2: e2.player,
            stakePerPlayer: stakePerPlayer,
            totalStaked: stakePerPlayer * 2,
            createdAt: uint64(block.timestamp),
            status: 1,
            winner: address(0)
        });

        
        playerStats[e1.player].totalStaked += stakePerPlayer;
        playerStats[e2.player].totalStaked += stakePerPlayer;

        emit QuickMatchCompleted(gameId, e1.player, e2.player, stakePerPlayer);
        emit GameCreated(gameId, e1.player, stakePerPlayer);
        emit GameJoined(gameId, e2.player);
    }

    
    
    

    function listMarketplaceItem(
        uint8 _characterId,
        uint128 _amount,
        uint128 _pricePerUnit
    ) external nonReentrant whenNotPaused {
        require(_amount > 0);
        require(_pricePerUnit >= MIN_CHARACTER_PRICE && _pricePerUnit <= MAX_CHARACTER_PRICE);
        require(coffyToken.getUserCharacterBalance(msg.sender, _characterId) >= _amount);

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
        require(item.isActive);
        require(_amount > 0 && _amount <= item.amount);
        require(msg.sender != item.seller);

        uint256 totalCost = uint256(item.pricePerUnit) * _amount;
        require(coffyToken.balanceOf(msg.sender) >= totalCost);

        item.amount -= _amount;
        if (item.amount == 0) item.isActive = false;

        coffyERC20.transferFrom(msg.sender, address(this), totalCost);

        uint256 fee = (totalCost * marketplaceFee) / 10000;
        uint256 sellerAmount = totalCost - fee;

        coffyERC20.transfer(item.seller, sellerAmount);

        if (fee > 0) {
            uint256 burnAmount = (fee * 2000) / 10000;
            uint256 treasuryAmount = fee - burnAmount;

            coffyERC20.transfer(DEAD, burnAmount);
            coffyERC20.transfer(coffyToken.treasury(), treasuryAmount);

            emit Burn(msg.sender, burnAmount, "marketplace_fee");
        }

        coffyToken.transferCharacterForModule(address(this), msg.sender, item.characterId, _amount);

        emit MarketplaceItemSold(_itemId, msg.sender, _amount);
    }

    function cancelMarketplaceItem(uint256 _itemId) external nonReentrant {
        MarketplaceItem storage item = marketplaceItems[_itemId];
        require(item.isActive);
        require(item.seller == msg.sender);

        uint128 lockedAmount = item.amount;
        item.isActive = false;

        coffyToken.transferCharacterForModule(address(this), msg.sender, item.characterId, lockedAmount);

        emit MarketplaceItemCancelled(_itemId);
    }

    
    
    

    function purchaseUpgrade(uint256 _upgradeId) external nonReentrant whenNotPaused {
        require(_upgradeId >= 1 && _upgradeId <= MAX_UPGRADE_ID);
        GameUpgrade storage upgrade = gameUpgrades[_upgradeId];
        require(upgrade.isActive);

        uint8 currentLevel = userUpgradeLevels[msg.sender][_upgradeId];
        require(currentLevel < 5);

        uint256 price = uint256(upgrade.price) * (currentLevel + 1);
        require(coffyToken.balanceOf(msg.sender) >= price);

        coffyERC20.transferFrom(msg.sender, DEAD, price);
        userUpgradeLevels[msg.sender][_upgradeId] = currentLevel + 1;

        emit UpgradePurchased(msg.sender, _upgradeId, currentLevel + 1, price);
        emit Burn(msg.sender, price, "upgrade");
    }

    
    
    

    function depositRewardPool(uint256 _amount) external nonReentrant {
        require(_amount > 0);
        coffyERC20.transferFrom(msg.sender, address(this), _amount);
        rewardPoolBalance += _amount;

        emit RewardPoolDeposited(msg.sender, _amount);
    }

    
    function claimSessionReward(
        bytes32 _sessionId,
        uint256 _amount,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        require(!usedSessionClaims[_sessionId]);
        require(_amount > 0);
        require(_amount <= maxRewardPerSession);
        require(rewardPoolBalance >= _amount);

        uint256 today = block.timestamp / 1 days;
        require(dailyRewardsClaimed[msg.sender][today] + _amount <= maxDailyRewardPerUser);

        bytes32 messageHash = keccak256(abi.encodePacked(
            "SESSION_REWARD",
            _sessionId,
            msg.sender,
            _amount,
            block.chainid,
            address(this)
        ));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        require(ethSignedHash.recover(_signature) == trustedSigner);

        usedSessionClaims[_sessionId] = true;
        dailyRewardsClaimed[msg.sender][today] += _amount;
        rewardPoolBalance -= _amount;

        coffyERC20.transfer(msg.sender, _amount);

        emit SessionRewardClaimed(msg.sender, _sessionId, _amount);
    }

    
    
    

    
    function _payCharacterBonus(address _winner, uint256 _totalPrize) internal returns (uint256) {
        if (!characterBonusEnabled) return 0;
        if (rewardPoolBalance == 0) return 0;

        uint256 bonusPct = 0;
        uint256 topCharId = 0;

        
        
        for (uint256 i = 5; i > 0; i--) {
            if (coffyToken.getUserCharacterBalance(_winner, i) > 0) {
                topCharId = i;
                bonusPct = i * 5; 
                break;
            }
        }

        if (bonusPct == 0) return 0;

        uint256 bonusAmount = (_totalPrize * bonusPct) / 100;

        
        if (rewardPoolBalance >= bonusAmount) {
            rewardPoolBalance -= bonusAmount;
            coffyERC20.transfer(_winner, bonusAmount);
            emit CharacterBonusPaid(_winner, topCharId, bonusAmount);
            return bonusAmount;
        }

        
        uint256 partialAmount = rewardPoolBalance;
        rewardPoolBalance = 0;
        coffyERC20.transfer(_winner, partialAmount);
        emit CharacterBonusPaid(_winner, topCharId, partialAmount);
        return partialAmount;
    }

    
    function _updateStats(
        address _winner,
        address _loser,
        uint256 _winnerPrize,
        bool _isDraw
    ) internal {
        if (_isDraw) return; 

        PlayerStats storage ws = playerStats[_winner];
        PlayerStats storage ls = playerStats[_loser];

        ws.totalGames += 1;
        ws.wins += 1;
        ws.totalWinnings += uint128(_winnerPrize);

        ls.totalGames += 1;
        ls.losses += 1;

        emit PlayerStatsUpdated(_winner, ws.totalGames, ws.wins);
        emit PlayerStatsUpdated(_loser, ls.totalGames, ls.wins);
    }

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
        require(ethSignedHash.recover(_signature) == trustedSigner);
    }

    
    
    

    // V5: Yeni CoffyCoin kontrati deploy edilince token adresini guncelle
    function setCoffyToken(address _newToken) external onlyRole(ADMIN_ROLE) {
        require(_newToken != address(0));
        coffyToken = ICoffyTokenV2(_newToken);
        coffyERC20 = IERC20(_newToken);
    }

    function setTrustedSigner(address _newSigner) external onlyRole(ADMIN_ROLE) {
        require(_newSigner != address(0));
        address oldSigner = trustedSigner;
        trustedSigner = _newSigner;
        emit SignerUpdated(oldSigner, _newSigner);
    }

    function setGameFee(uint16 _fee) external onlyRole(ADMIN_ROLE) {
        require(_fee <= 1000);
        gameFee = _fee;
    }

    function setBattleFee(uint16 _fee) external onlyRole(ADMIN_ROLE) {
        require(_fee <= 1000);
        battleFee = _fee;
    }

    function setMarketplaceFee(uint16 _fee) external onlyRole(ADMIN_ROLE) {
        require(_fee <= 1000);
        marketplaceFee = _fee;
    }

    function setBattleExpiration(uint32 _expiration) external onlyRole(ADMIN_ROLE) {
        require(_expiration >= 1 hours && _expiration <= 7 days);
        battleExpiration = _expiration;
    }

    function setQueueExpiration(uint32 _expiration) external onlyRole(ADMIN_ROLE) {
        require(_expiration >= 1 minutes && _expiration <= 1 hours);
        queueExpiration = _expiration;
    }

    function setMaxRewardPerSession(uint256 _max) external onlyRole(ADMIN_ROLE) {
        maxRewardPerSession = _max;
    }

    function setMaxDailyRewardPerUser(uint256 _max) external onlyRole(ADMIN_ROLE) {
        maxDailyRewardPerUser = _max;
    }

    function setCharacterBonusEnabled(bool _enabled) external onlyRole(ADMIN_ROLE) {
        characterBonusEnabled = _enabled;
    }

    function setGameAbandonTimeout(uint32 _timeout) external onlyRole(ADMIN_ROLE) {
        require(_timeout >= 30 minutes && _timeout <= 7 days);
        gameAbandonTimeout = _timeout;
    }

    function setGameUpgrade(
        uint256 _upgradeId,
        uint128 _price,
        uint8 _upgradeType,
        uint8 _upgradeValue,
        bool _isActive
    ) external onlyRole(ADMIN_ROLE) {
        require(_upgradeId >= 1 && _upgradeId <= MAX_UPGRADE_ID);
        gameUpgrades[_upgradeId] = GameUpgrade({
            price: _price,
            upgradeType: _upgradeType,
            upgradeValue: _upgradeValue,
            isActive: _isActive
        });
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function emergencyCancelGame(uint256 _gameId) external onlyRole(ADMIN_ROLE) {
        Game storage game = games[_gameId];
        require(game.status == 0 || game.status == 1);

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
        require(battle.status == 0 || battle.status == 1);

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

    
    function withdrawAvailableFunds(address _to, uint256 _amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(_to != address(0));
        uint256 totalBalance = coffyToken.balanceOf(address(this));
        uint256 locked = totalLockedStakes + rewardPoolBalance;
        uint256 available = totalBalance > locked ? totalBalance - locked : 0;
        require(_amount <= available);
        coffyERC20.transfer(_to, _amount);
    }
}
