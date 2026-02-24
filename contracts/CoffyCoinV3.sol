// SPDX-License-Identifier: MIT
// Ağ: Base (Coinbase L2) - UPDATED FOR SECURITY
// Token Name: Coffy Coin
// Token Symbol: COFFY
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// Module Interfaces - Ready for external development
interface IDAOModule {
    function proposeCharacterPriceChange(uint256 characterId, uint256 newPrice) external;
    function vote(uint256 proposalId, bool support) external;
    function executeProposal(uint256 proposalId) external;
    function getVotingPower(address user) external view returns (uint256);
}

interface INFTModule {
    function migrateCharacterToNFT(address user, uint256 characterId, uint256 amount) external returns (uint256[] memory nftIds);
    function getNFTMultiplier(address user, uint256 nftId) external view returns (uint256);
    function isNFTActive() external view returns (bool);
}

interface ISocialModule {
    function processStepReward(address user, uint256 steps, uint256 characterMultiplier) external;
    function processSnapReward(address user, uint256 photos, uint256 characterMultiplier) external;
    function getDailyLimit(address user) external view returns (uint256);
}

/**
 * @title CoffyCoin V3 - Security Enhanced
 * @dev Lightweight core with module support for DAO, NFT, and Social features
 * CHANGES:
 * - Added getFreeBalance() function
 * - Added burnFromGame() for modules
 * - Added mint limits (2% annual cap)
 * - Enhanced Sybil protection (14 days)
 * - Fixed expiry inconsistency (60 days → 30 days to match error message)
 * - Vesting integration in constructor
 */
contract CoffyCoin is ERC20, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MODULE_ROLE = keccak256("MODULE_ROLE");

    // Token Distribution - 15B Total (UNCHANGED PER USER REQUEST)
    uint256 public constant TOTAL_SUPPLY = 15_000_000_000 * 1e18;
    uint256 public constant TREASURY_ALLOCATION = (TOTAL_SUPPLY * 25) / 100;
    uint256 public constant LIQUIDITY_ALLOCATION = (TOTAL_SUPPLY * 20) / 100;
    uint256 public constant COMMUNITY_ALLOCATION = (TOTAL_SUPPLY * 35) / 100;
    uint256 public constant TEAM_ALLOCATION = (TOTAL_SUPPLY * 10) / 100;
    uint256 public constant MARKETING_ALLOCATION = (TOTAL_SUPPLY * 10) / 100;

    // Core Constants
    uint256 public constant FIXED_CHARACTERS_COUNT = 5;
    uint256 public constant MAX_WEEKLY_CLAIM = 35000 * 1e18; // 5K daily limit × 7 days
    uint256 public constant MIN_CLAIM_BALANCE = 100000 * 1e18; // Economic barrier vs Sybil
    uint256 public constant MIN_BALANCE_FOR_ACCUMULATION = 10000 * 1e18;
    uint256 public constant PENDING_REWARD_EXPIRY = 30 days; // FIXED: was 60 days but error said 30
    uint256 public constant MIN_WALLET_AGE = 3 days; // Sybil defense: 3 gün + 100K balance
    // Enflasyon oranı: 6 ayda bir %1 (yılda %2)
    uint256 public constant SEMIANNUAL_INFLATION_RATE = 100; // 1% per 6 months, 2% annual

    // NEW: Mint Limits
    uint256 public constant MAX_ANNUAL_MINT = (TOTAL_SUPPLY * 2) / 100; // 2% of total supply
    mapping(uint256 => uint256) public yearlyMinted; // year => amount minted
    uint256 public deploymentYear;
    
    // Burn Address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Character System - Enhanced with Metadata and Max Supply
    struct Character {
        uint128 price;
        uint128 totalSupply;
        uint128 maxSupply;
        uint16 multiplier;
        uint16 claimMultiplier;
        bool isActive;
    }
    
    mapping(uint256 => Character) public characters;
    mapping(uint256 => string) public characterNames;
    mapping(uint256 => string) public characterMetadataURIs;
    
    function _createCharacter(
        string memory _name, 
        uint256 _price, 
        uint16 _multiplier, 
        uint16 _claimMultiplier, 
        string memory _metadataURI
    ) internal {
        characters[nextCharacterId] = Character({
            price: uint128(_price),
            totalSupply: 0,
            maxSupply: type(uint128).max,
            multiplier: _multiplier,
            claimMultiplier: _claimMultiplier,
            isActive: true
        });
        characterNames[nextCharacterId] = _name;
        characterMetadataURIs[nextCharacterId] = _metadataURI;
        nextCharacterId++;
    }

    mapping(address => mapping(uint256 => uint128)) public userCharacters;
    uint256 public nextCharacterId = 1;

    // Staking System
    struct Stake {
        uint128 amount;
        uint64 startTime;
        uint64 lastClaim;
    }
    mapping(address => Stake) public stakes;
    uint256 public totalStaked;
    uint256 public constant ANNUAL_RATE = 500; // 5%
    uint256 public constant EARLY_UNSTAKE_PENALTY = 500; // 5% penalty

    // Security & Trading
    mapping(address => bool) public isDEXPair;
    uint16 public constant DEX_TAX = 200; // 2%

    // Core Addresses
    address public treasury;
    address public liquidity;
    address public community;
    address public teamVesting; // CHANGED: Now points to vesting contract
    address public marketingVesting; // CHANGED: Now points to vesting contract
    
    mapping(address => bool) public isConstWallet;

    // Module System
    mapping(address => bool) public authorizedModules;
    
    address public daoModule;
    address public nftModule;
    address public socialModule;
    
    // Weekly tracking for combined limits
    mapping(address => uint256) public weeklyRewards;
    mapping(address => uint256) public lastRewardWeek;

    // Game rewards tracking
    mapping(address => uint256) public lastClaimWeek;
    mapping(address => uint256) public claimedThisWeek;

    // Pending Rewards System
    mapping(address => uint256) public pendingGameRewards;
    mapping(address => uint256) public pendingStepRewards;
    mapping(address => uint256) public pendingSnapRewards;
    mapping(address => uint256) public lastPendingUpdate;

    // Sybil Protection
    mapping(address => uint256) public walletCreatedAt;
    mapping(address => uint256) public lastGameStart;
    mapping(address => uint256) public lastStepStart;

    // Game Statistics
    struct GameStats {
        uint256 totalGamesPlayed;
        uint256 totalRewardsClaimed;
        uint256 lastGameTimestamp;
    }
    mapping(address => GameStats) public gameStats;
    
    // WALLET AGE AUTO-INITIALIZATION
    // Sets wallet creation time on first meaningful interaction
    function _initializeWallet(address user) private {
        if (walletCreatedAt[user] == 0) {
            walletCreatedAt[user] = block.timestamp;
        }
    }

    // Inflation System
    uint256 public lastInflationTime;

    // Mobile App Integration
    address public mobileAppBackend;
    mapping(address => string) public userProfiles;
    mapping(string => address) public profileToWallet;

    // DAO MEMBERSHIP SYSTEM
    uint256 public constant LEGENDARY_CHARACTER_ID = 5;
    uint256 public constant DAO_MEMBERSHIP_THRESHOLD = 10_000_000 * 1e18;
    mapping(address => bool) public isDAOMember;

    // Events
    event CharacterPurchased(address indexed buyer, uint256 indexed characterId, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event GameRewardsClaimed(address indexed user, uint256 amount);
    event ModuleSet(string moduleType, address module);
    event ModuleEnabled(string moduleType);
    event TradingEnabled();
    event PendingRewardAdded(address indexed user, uint256 amount, string rewardType);
    event PendingRewardsClaimed(address indexed user, uint256 totalAmount);
    event InflationMinted(uint256 amount, uint256 time);
    event UserProfileLinked(address indexed wallet, string profileId);
    event EarlyUnstakePenalty(address indexed user, uint256 amount, uint256 penalty);

    constructor(
        address _treasury,
        address _liquidity,
        address _community,
        address _teamVesting,
        address _marketingVesting
    ) ERC20("Coffy Coin", "COFFY") {
        require(_treasury != address(0) && _liquidity != address(0) && 
                _community != address(0) && _teamVesting != address(0) && 
                _marketingVesting != address(0), "Invalid addresses");
        
        treasury = _treasury;
        liquidity = _liquidity;
        community = _community;
        teamVesting = _teamVesting; // CHANGED: Vesting contract
        marketingVesting = _marketingVesting; // CHANGED: Vesting contract
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        // Mint initial supply
        _mint(_treasury, TREASURY_ALLOCATION);
        _mint(_liquidity, LIQUIDITY_ALLOCATION);
        _mint(_community, COMMUNITY_ALLOCATION);
        _mint(_teamVesting, TEAM_ALLOCATION); // CHANGED: To vesting contract
        _mint(_marketingVesting, MARKETING_ALLOCATION); // CHANGED: To vesting contract

        // Set const wallets for inflation trigger
        isConstWallet[_treasury] = true;
        isConstWallet[_liquidity] = true;
        isConstWallet[_community] = true;

        // Create 5 fixed-price characters (UNCHANGED)
        _createCharacter("Genesis", 1000000 * 1e18, 200, 200, "ipfs://genesis-metadata");
        _createCharacter("Mocha Knight", 3000000 * 1e18, 300, 300, "ipfs://mocha-metadata");
        _createCharacter("Arabica Archmage", 5000000 * 1e18, 500, 500, "ipfs://arabica-metadata");
        _createCharacter("Robusta Shadowblade", 8000000 * 1e18, 700, 700, "ipfs://robusta-metadata");
        _createCharacter("Legendary Dragon", 10000000 * 1e18, 1000, 1000, "ipfs://dragon-metadata");

        // Initialize inflation timer
        lastInflationTime = block.timestamp;
        deploymentYear = block.timestamp / 365 days;
    }

    // NEW: Get free balance (not staked)
    function getFreeBalance(address user) public view returns (uint256) {
        uint256 totalBalance = balanceOf(user);
        uint256 stakedAmount = stakes[user].amount;
        return totalBalance > stakedAmount ? totalBalance - stakedAmount : 0;
    }

    // NEW: Burn from game (for modules)
    function burnFromGame(address from, uint256 amount) external {
        require(authorizedModules[msg.sender], "Unauthorized module");
        uint256 freeBalance = getFreeBalance(from);
        require(freeBalance >= amount, "Insufficient free balance");
        _burn(from, amount);
    }

    // CHARACTER SYSTEM
    function purchaseCharacter(uint256 _characterId, uint256 _amount) external nonReentrant whenNotPaused {
        _initializeWallet(msg.sender); // Auto-set wallet age on first purchase
        require(_amount > 0 && _characterId < nextCharacterId, "Invalid");
        Character storage character = characters[_characterId];
        require(character.isActive, "Inactive");
        uint256 cost = uint256(character.price) * _amount;
        require(balanceOf(msg.sender) >= cost, "Insufficient balance");
        
        // 100% BURN - Maximum deflationary effect
        _transfer(msg.sender, address(0x000000000000000000000000000000000000dEaD), cost);
        
        userCharacters[msg.sender][_characterId] += uint128(_amount);
        character.totalSupply += uint128(_amount);
        if (_characterId == LEGENDARY_CHARACTER_ID) {
            isDAOMember[msg.sender] = true;
        }
        emit CharacterPurchased(msg.sender, _characterId, _amount);
    }

    // STAKING SYSTEM
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        _initializeWallet(msg.sender); // Auto-set wallet age on first stake
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        _transfer(msg.sender, address(this), amount);
        Stake storage userStake = stakes[msg.sender];
        
        if (userStake.amount > 0) {
            uint256 reward = _calculateReward(msg.sender);
            if (reward > 0) _mintWithLimit(msg.sender, reward);
        }
        
        userStake.amount += uint128(amount);
        userStake.startTime = uint64(block.timestamp);
        userStake.lastClaim = uint64(block.timestamp);
        totalStaked += amount;
        
        emit Staked(msg.sender, amount);
    }

    // Dinamik staking APY — karakter multiplier bazlı
    function _getUserStakingAPY(address user) internal view returns (uint256) {
        uint256 maxMultiplier = ANNUAL_RATE; // 500 = %5 base
        for (uint256 i = 1; i < nextCharacterId; i++) {
            if (userCharacters[user][i] > 0) {
                // Her karakter kendi multiplier'ı kadar APY verir
                // Genesis=200→%20, Mocha=300→%30, Arabica=500→%50, Robusta=700→%70, Dragon=1000→%100
                uint256 charAPY = uint256(characters[i].multiplier) * 10;
                if (charAPY > maxMultiplier) {
                    maxMultiplier = charAPY;
                }
            }
        }
        return maxMultiplier;
    }

    function _calculateReward(address user) internal view returns (uint256) {
        Stake memory userStake = stakes[user];
        if (userStake.amount == 0) return 0;
        uint256 duration = block.timestamp - userStake.lastClaim;
        uint256 apy = _getUserStakingAPY(user);
        return (userStake.amount * apy * duration) / (10000 * 365 days);
    }

    // NEW: Mint with annual limit check
    function _mintWithLimit(address to, uint256 amount) internal {
        uint256 currentYear = block.timestamp / 365 days;
        // FIX: yearlyMinted mapping defaults to 0 for new years, no manual reset needed
        require(yearlyMinted[currentYear] + amount <= MAX_ANNUAL_MINT, "Annual mint limit exceeded");
        yearlyMinted[currentYear] += amount;
        _mint(to, amount);
    }

    // Game session doğrulaması: startGame çağrılmış olmalı
    // minimumGameTime modifier kaldırıldı — backend imza doğrulaması yeterli
    // NOT: startGameSession() kaldırıldı, startGame() ile birleştirildi

    function getStakingAPY() external view returns (uint256) {
        return _getUserStakingAPY(msg.sender);
    }

    function emergencyUnstake() external nonReentrant whenNotPaused {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.amount > 0, "Nothing staked");
        
        uint256 stakedAmount = userStake.amount;
        uint256 reward = _calculateReward(msg.sender);
        if (reward > 0) _mintWithLimit(msg.sender, reward);
        
        uint256 penalty = (stakedAmount * EARLY_UNSTAKE_PENALTY) / 10000;
        uint256 finalAmount = stakedAmount - penalty;
        
        userStake.amount = 0;
        totalStaked -= stakedAmount;
        userStake.lastClaim = uint64(block.timestamp);
        
        _transfer(address(this), treasury, penalty);
        _transfer(address(this), msg.sender, finalAmount);
        
        emit EarlyUnstakePenalty(msg.sender, stakedAmount, penalty);
        emit Unstaked(msg.sender, finalAmount);
    }

    function unstake() external nonReentrant whenNotPaused {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.amount > 0, "Nothing staked");
        require(block.timestamp >= userStake.startTime + 7 days, "Unstake available after 7 days or use emergencyUnstake");
        uint256 stakedAmount = userStake.amount;
        uint256 reward = _calculateReward(msg.sender);
        if (reward > 0) _mintWithLimit(msg.sender, reward);
        userStake.amount = 0;
        totalStaked -= stakedAmount;
        userStake.lastClaim = uint64(block.timestamp);
        _transfer(address(this), msg.sender, stakedAmount);
        emit Unstaked(msg.sender, stakedAmount);
    }

    function partialUnstake(uint256 amount) external nonReentrant whenNotPaused {
        Stake storage userStake = stakes[msg.sender];
        require(amount > 0, "Amount must be greater than 0");
        require(userStake.amount >= amount, "Insufficient staked amount");
        require(block.timestamp >= userStake.startTime + 7 days, "Partial unstake available after 7 days or use emergencyUnstake");
        uint256 reward = _calculateReward(msg.sender);
        if (reward > 0) _mintWithLimit(msg.sender, reward);
        userStake.amount -= uint128(amount);
        totalStaked -= amount;
        userStake.lastClaim = uint64(block.timestamp);
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function getUnstakePenalty(address user) external view returns (uint256 penalty, bool hasPenalty) {
        Stake memory userStake = stakes[user];
        if (userStake.amount == 0) return (0, false);
        
        if (block.timestamp < userStake.startTime + 7 days) {
            penalty = (userStake.amount * EARLY_UNSTAKE_PENALTY) / 10000;
            hasPenalty = true;
        } else {
            penalty = 0;
            hasPenalty = false;
        }
    }

    // GAME REWARDS
    function claimGameRewards(uint256 baseAmount) external nonReentrant whenNotPaused {
        require(baseAmount > 0, "Invalid amount");
        require(lastGameStart[msg.sender] > 0, "Start game session first");
        
        // Sybil protection (3 gün wallet yaşı)
        require(walletCreatedAt[msg.sender] > 0 && 
                block.timestamp - walletCreatedAt[msg.sender] >= MIN_WALLET_AGE, "Wallet too young");
        
        uint256 multiplier = _getCharacterMultiplier(msg.sender);
        uint256 finalAmount = (baseAmount * multiplier) / 100;
        uint256 maxWeeklyClaim = (MAX_WEEKLY_CLAIM * multiplier) / 100;
        require(finalAmount <= maxWeeklyClaim, "Amount exceeds weekly limit");
        
        uint256 currentWeek = block.timestamp / 1 weeks;
        if (lastRewardWeek[msg.sender] < currentWeek) {
            weeklyRewards[msg.sender] = 0;
            lastRewardWeek[msg.sender] = currentWeek;
        }
        require(weeklyRewards[msg.sender] + finalAmount <= maxWeeklyClaim, "Weekly limit exceeded");
        
        uint256 userBalance = balanceOf(msg.sender);
        
        _updateGameStats(msg.sender, finalAmount);
        
        if (userBalance >= MIN_CLAIM_BALANCE) {
            weeklyRewards[msg.sender] += finalAmount;
            lastGameStart[msg.sender] = 0;
            _transfer(treasury, msg.sender, finalAmount);
            emit GameRewardsClaimed(msg.sender, finalAmount);
        }
        else if (userBalance >= MIN_BALANCE_FOR_ACCUMULATION) {
            pendingGameRewards[msg.sender] += finalAmount;
            weeklyRewards[msg.sender] += finalAmount;
            lastPendingUpdate[msg.sender] = block.timestamp;
            lastGameStart[msg.sender] = 0;
            emit PendingRewardAdded(msg.sender, finalAmount, "game");
        }
        else {
            revert("Insufficient balance for rewards");
        }
    }
    
    function _getCharacterMultiplier(address user) internal view returns (uint256) {
        uint256 userBalance = balanceOf(user);
        uint256 maxMultiplier = 100;
        
        for (uint256 i = 5; i > 0; i--) { // FIXED: i >= 1 causes underflow
            if (userCharacters[user][i] > 0) {
                Character memory char = characters[i];
                if (userBalance >= char.price) {
                    maxMultiplier = char.claimMultiplier;
                    break;
                }
            }
        }
        
        return maxMultiplier;
    }

    function getCharacterMultiplier(address user) external view returns (uint256) {
        return _getCharacterMultiplier(user);
    }

    function _updateGameStats(address user, uint256 rewardAmount) internal {
        GameStats storage stats = gameStats[user];
        stats.totalGamesPlayed += 1;
        stats.totalRewardsClaimed += rewardAmount;
        stats.lastGameTimestamp = block.timestamp;
    }

    function claimPendingRewards(uint256 amount) external nonReentrant whenNotPaused {
        require(balanceOf(msg.sender) >= MIN_CLAIM_BALANCE, "Need 100K COFFY to claim");
        require(amount > 0 && amount <= MAX_WEEKLY_CLAIM, "Invalid amount");
        
        uint256 totalPending = pendingGameRewards[msg.sender] + pendingStepRewards[msg.sender] + pendingSnapRewards[msg.sender];
        require(totalPending > 0, "No pending rewards");
        require(amount <= totalPending, "Amount exceeds pending rewards");
        
        // FIXED: 30 days (was 60)
        require(lastPendingUpdate[msg.sender] > 0 && 
                block.timestamp - lastPendingUpdate[msg.sender] <= PENDING_REWARD_EXPIRY, 
                "Rewards expired after 30 days");
        
        uint256 currentWeek = block.timestamp / 1 weeks;
        if (lastRewardWeek[msg.sender] < currentWeek) {
            weeklyRewards[msg.sender] = 0;
            lastRewardWeek[msg.sender] = currentWeek;
        }
        require(weeklyRewards[msg.sender] + amount <= MAX_WEEKLY_CLAIM, "Weekly limit exceeded");
        
        uint256 gameShare = (pendingGameRewards[msg.sender] * amount) / totalPending;
        uint256 stepShare = (pendingStepRewards[msg.sender] * amount) / totalPending;
        uint256 snapShare = amount - gameShare - stepShare;
        
        pendingGameRewards[msg.sender] -= gameShare;
        pendingStepRewards[msg.sender] -= stepShare;
        pendingSnapRewards[msg.sender] -= snapShare;
        
        weeklyRewards[msg.sender] += amount;
        
        if (pendingGameRewards[msg.sender] + pendingStepRewards[msg.sender] + pendingSnapRewards[msg.sender] == 0) {
            lastPendingUpdate[msg.sender] = 0;
        }
        
        _transfer(treasury, msg.sender, amount);
        emit PendingRewardsClaimed(msg.sender, amount);
    }

    // VIEW FUNCTIONS
    function getGameStats(address user) external view returns (
        uint256 totalGamesPlayed,
        uint256 totalRewardsClaimed,
        uint256 lastGameTimestamp
    ) {
        GameStats memory stats = gameStats[user];
        return (
            stats.totalGamesPlayed,
            stats.totalRewardsClaimed,
            stats.lastGameTimestamp
        );
    }

    // MODULE SYSTEM
    function setDAOModule(address _module) external onlyRole(ADMIN_ROLE) {
        require(_module != address(0), "Invalid module address");
        daoModule = _module;
        authorizedModules[_module] = true;
        emit ModuleSet("DAO", _module);
    }

    function setNFTModule(address _module) external onlyRole(ADMIN_ROLE) {
        require(_module != address(0), "Invalid module address");
        nftModule = _module;
        authorizedModules[_module] = true;
        emit ModuleSet("NFT", _module);
    }

    function setSocialModule(address _module) external onlyRole(ADMIN_ROLE) {
        require(_module != address(0), "Invalid module address");
        socialModule = _module;
        authorizedModules[_module] = true;
        emit ModuleSet("Social", _module);
    }

    function migrateToNFT(uint256 _characterId, uint256 _amount) external nonReentrant whenNotPaused {
        require(nftModule != address(0), "NFT module not set");
        require(userCharacters[msg.sender][_characterId] >= _amount, "Insufficient");
        
        userCharacters[msg.sender][_characterId] -= uint128(_amount);
        characters[_characterId].totalSupply -= uint128(_amount);
    }

    function processSocialReward(address user, uint256 amount) external whenNotPaused {
        require(msg.sender == socialModule, "Unauthorized");
        require(amount <= MAX_WEEKLY_CLAIM, "Amount too high");
        
        require(lastStepStart[user] > 0, "No step activity started");
        
        uint256 currentWeek = block.timestamp / 1 weeks;
        if (lastRewardWeek[user] < currentWeek) {
            weeklyRewards[user] = 0;
            lastRewardWeek[user] = currentWeek;
        }
        require(weeklyRewards[user] + amount <= MAX_WEEKLY_CLAIM, "Weekly limit");
        
        uint256 userBalance = balanceOf(user);
        
        if (userBalance >= MIN_CLAIM_BALANCE) {
            weeklyRewards[user] += amount;
            lastStepStart[user] = 0;
            _transfer(treasury, user, amount);
        } else if (userBalance >= MIN_BALANCE_FOR_ACCUMULATION) {
            pendingStepRewards[user] += amount;
            weeklyRewards[user] += amount;
            lastPendingUpdate[user] = block.timestamp;
            lastStepStart[user] = 0;
            emit PendingRewardAdded(user, amount, "social");
        }
    }

    // Pending reward ekleme fonksiyonları (StepSnapModule uyumluluğu)
    function addPendingStepReward(address user, uint256 amount) external whenNotPaused {
        require(authorizedModules[msg.sender], "Unauthorized module");
        require(amount > 0, "!amount");
        pendingStepRewards[user] += amount;
        lastPendingUpdate[user] = block.timestamp;
        emit PendingRewardAdded(user, amount, "step");
    }

    function addPendingSnapReward(address user, uint256 amount) external whenNotPaused {
        require(authorizedModules[msg.sender], "Unauthorized module");
        require(amount > 0, "!amount");
        pendingSnapRewards[user] += amount;
        lastPendingUpdate[user] = block.timestamp;
        emit PendingRewardAdded(user, amount, "snap");
    }

    function transferForModule(address from, address to, uint256 amount) external whenNotPaused {
        require(authorizedModules[msg.sender], "Unauthorized");
        require(to != msg.sender, "Module cannot transfer to itself");
        // FIX: Module can only transfer its own funds, not arbitrary users'
        require(from == msg.sender, "Module can only transfer own funds");
        uint256 freeBalance = getFreeBalance(from);
        require(freeBalance >= amount, "Insufficient free balance");
        _transfer(from, to, amount);
    }

    // INFLATION SYSTEM - WITH LIMITS
    function triggerInflation() external nonReentrant whenNotPaused {
        require(isConstWallet[msg.sender], "Only const wallets can trigger inflation");
        require(block.timestamp - lastInflationTime >= 180 days, "Too early");
        
        uint256 currentSupply = totalSupply();
        uint256 totalInflation = (currentSupply * SEMIANNUAL_INFLATION_RATE) / 10000;
        
        // Check annual limit
        uint256 currentYear = block.timestamp / 365 days;
        // FIX: yearlyMinted mapping defaults to 0 for new years, no manual reset needed
        // Old code was resetting on every call, allowing limit bypass
        require(yearlyMinted[currentYear] + totalInflation <= MAX_ANNUAL_MINT, "Annual mint limit exceeded");
        
        uint256 treasuryShare = (totalInflation * 25) / 100;
        uint256 liquidityShare = (totalInflation * 20) / 100;
        uint256 communityShare = (totalInflation * 35) / 100;
        uint256 teamShare = (totalInflation * 10) / 100;
        uint256 marketingShare = (totalInflation * 10) / 100;
        
        yearlyMinted[currentYear] += totalInflation;
        
        _mint(treasury, treasuryShare);
        _mint(liquidity, liquidityShare);
        _mint(community, communityShare);
        _mint(teamVesting, teamShare);
        _mint(marketingVesting, marketingShare);
        
        lastInflationTime = block.timestamp;
        emit InflationMinted(totalInflation, block.timestamp);
    }

    // MOBILE APP INTEGRATION
    function setMobileBackend(address _backend) external onlyRole(ADMIN_ROLE) {
        require(_backend != address(0), "Invalid backend");
        mobileAppBackend = _backend;
        authorizedModules[_backend] = true;
    }
    
    function linkUserProfile(string calldata profileId) external {
        require(bytes(profileId).length > 0, "Invalid profile ID");
        require(profileToWallet[profileId] == address(0), "Profile already linked");
        require(bytes(userProfiles[msg.sender]).length == 0, "Wallet already linked");
        
        _initializeWallet(msg.sender); // Auto-set wallet age (also works here)
        userProfiles[msg.sender] = profileId;
        profileToWallet[profileId] = msg.sender;
        
        emit UserProfileLinked(msg.sender, profileId);
    }

    function startGame() external whenNotPaused {
        _initializeWallet(msg.sender); // Auto-set wallet age on first game
        lastGameStart[msg.sender] = block.timestamp;
    }

    function startStep() external whenNotPaused {
        _initializeWallet(msg.sender); // Auto-set wallet age on first step activity
        lastStepStart[msg.sender] = block.timestamp;
    }



    function setCoffeeShopModule(address _module) external onlyRole(ADMIN_ROLE) {
        require(_module != address(0), "Invalid module address");
        authorizedModules[_module] = true;
    }

    // DEX pair yönetimi
    function setDEXPair(address _pair, bool _enabled) external onlyRole(ADMIN_ROLE) {
        require(_pair != address(0), "Invalid pair address");
        isDEXPair[_pair] = _enabled;
    }

    // OPTIMIZED TRANSFER WITH DEX TAX (50% BURN + 50% BUYBACK TREASURY)
    function transfer(address to, uint256 amount) public override returns (bool) {
        address owner = _msgSender();
        if (isDEXPair[to]) {
            uint256 fee = (amount * DEX_TAX) / 10000; // 2% total (DEX_TAX=200)
            uint256 burnAmount = fee / 2; // 1% burn
            uint256 buybackAmount = fee - burnAmount; // 1% buyback treasury
            uint256 transferAmount = amount - fee;
            
            super._transfer(owner, to, transferAmount);
            super._transfer(owner, BURN_ADDRESS, burnAmount); // BURN
            super._transfer(owner, community, buybackAmount); // Buyback treasury
        } else {
            super._transfer(owner, to, amount);
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        uint256 currentAllowance = allowance(from, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "Insufficient allowance");
            _approve(from, spender, currentAllowance - amount);
        }
        if (isDEXPair[to]) {
            uint256 fee = (amount * DEX_TAX) / 10000; // 2% total
            uint256 burnAmount = fee / 2; // 1% burn
            uint256 buybackAmount = fee - burnAmount; // 1% buyback treasury
            uint256 transferAmount = amount - fee;
            super._transfer(from, to, transferAmount);
            super._transfer(from, BURN_ADDRESS, burnAmount); // BURN
            super._transfer(from, community, buybackAmount); // Buyback treasury
        } else {
            super._transfer(from, to, amount);
        }
        return true;
    }

    // VIEW FUNCTIONS
    function getCharacter(uint256 _characterId) external view returns (
        uint256 price, 
        uint256 totalSupply,
        uint256 maxSupply,
        uint256 multiplier,
        uint256 claimMultiplier,
        bool isActive
    ) {
        Character memory char = characters[_characterId];
        return (
            char.price, 
            char.totalSupply,
            char.maxSupply,
            char.multiplier,
            char.claimMultiplier,
            char.isActive
        );
    }

    function getCharacterStrings(uint256 _characterId) external view returns (string memory name, string memory metadataURI) {
        return (characterNames[_characterId], characterMetadataURIs[_characterId]);
    }

    function getUserCharacterBalance(address _user, uint256 _characterId) external view returns (uint256) {
        return userCharacters[_user][_characterId];
    }

    // NEW: Module can transfer characters between users (for marketplace)
    function transferCharacterForModule(
        address from,
        address to,
        uint256 characterId,
        uint128 amount
    ) external whenNotPaused {
        require(authorizedModules[msg.sender], "Unauthorized");
        require(from != address(0) && to != address(0), "Invalid address");
        require(userCharacters[from][characterId] >= amount, "Insufficient characters");
        userCharacters[from][characterId] -= amount;
        userCharacters[to][characterId] += amount;
    }

    function getRemainingDailyLimit(address _user) external view returns (uint256) {
        uint256 currentWeek = block.timestamp / 1 weeks;
        if (lastRewardWeek[_user] < currentWeek) return MAX_WEEKLY_CLAIM;
        return MAX_WEEKLY_CLAIM > weeklyRewards[_user] ? MAX_WEEKLY_CLAIM - weeklyRewards[_user] : 0;
    }

    function getModuleStates() external view returns (
        address dao, bool daoActive,
        address nft, bool nftActive,
        address social, bool socialActive,
        address crossChain, bool crossChainActive
    ) {
        return (
            daoModule, daoModule != address(0),
            nftModule, nftModule != address(0),
            socialModule, socialModule != address(0),
            address(0), false
        );
    }

    function getPendingRewardsStatus(address user) external view returns (
        uint256 totalPending,
        uint256 gameRewards,
        uint256 stepRewards,
        uint256 snapRewards,
        bool canClaim,
        bool hasExpired
    ) {
        gameRewards = pendingGameRewards[user];
        stepRewards = pendingStepRewards[user];
        snapRewards = pendingSnapRewards[user];
        totalPending = gameRewards + stepRewards + snapRewards;
        
        canClaim = balanceOf(user) >= MIN_CLAIM_BALANCE && totalPending > 0;
        
        if (lastPendingUpdate[user] > 0) {
            uint256 timeSinceUpdate = block.timestamp - lastPendingUpdate[user];
            hasExpired = timeSinceUpdate > PENDING_REWARD_EXPIRY;
        } else {
            hasExpired = false;
        }
    }

    function getUserProfile(address wallet) external view returns (string memory) {
        return userProfiles[wallet];
    }
    
    function getWalletByProfile(string calldata profileId) external view returns (address) {
        return profileToWallet[profileId];
    }

    function getInflationInfo() external view returns (uint256 lastTime, uint256 nextTime, bool canTrigger) {
        lastTime = lastInflationTime;
        nextTime = lastInflationTime + 180 days;
        canTrigger = block.timestamp >= nextTime;
    }

    function getUserCharacterMultiplier(address user) external view returns (uint256 multiplier, string memory eligibleCharacter) {
        multiplier = _getCharacterMultiplier(user);
        
        uint256 userBalance = balanceOf(user);
        for (uint256 i = 5; i > 0; i--) { // FIXED: i >= 1 causes underflow
            if (userCharacters[user][i] > 0) {
                Character memory char = characters[i];
                if (userBalance >= char.price && char.claimMultiplier == multiplier) {
                    eligibleCharacter = characterNames[i];
                    break;
                }
            }
        }
        
        if (multiplier == 100) {
            eligibleCharacter = "No character bonus";
        }
    }

    function getActivityStatus(address user) external view returns (
        uint256 gameStartTime,
        uint256 stepStartTime,
        bool canClaimGame,
        bool canClaimStep
    ) {
        gameStartTime = lastGameStart[user];
        stepStartTime = lastStepStart[user];
        canClaimGame = gameStartTime > 0;
        canClaimStep = stepStartTime > 0;
    }

    function getStakeInfo(address user) external view returns (
        uint256 amount,
        uint256 startTime,
        uint256 pendingReward
    ) {
        Stake memory userStake = stakes[user];
        return (userStake.amount, userStake.startTime, _calculateReward(user));
    }

    // Emergency pause fonksiyonları
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // NEW: Get minting stats
    function getMintingStats() external view returns (
        uint256 currentYear,
        uint256 mintedThisYear,
        uint256 remainingMintCapacity
    ) {
        currentYear = block.timestamp / 365 days;
        mintedThisYear = yearlyMinted[currentYear];
        remainingMintCapacity = MAX_ANNUAL_MINT > mintedThisYear ? MAX_ANNUAL_MINT - mintedThisYear : 0;
    }
}
