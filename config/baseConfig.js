// Base Network Configuration for CoffyCoin
// Updated: 2026-02-07
import CoffyCoinABI from './CoffyCoinABI.json';
import AuxiliaryABI from './AuxiliaryABI.json';

export const BASE_CONFIG = {
    // Network Info
    CHAIN_ID: 8453,
    CHAIN_ID_HEX: '0x2105',
    CHAIN_NAME: 'Base Mainnet',
    RPC_URL: 'https://mainnet.base.org',
    EXPLORER_URL: 'https://basescan.org',
    EXPLORER_NAME: 'BaseScan',
    NATIVE_CURRENCY: {
        name: 'Ethereum',
        symbol: 'ETH',
        decimals: 18
    },

    // Contract Addresses
    CONTRACTS: {
        CoffyCoin: '0xBf6679b911e087c3Bb096867Ecb45cBAec2847Be',
        Battle: '0x5796f53758C5706A55A27352D29b8142bC026525',
        Airdrop: '0x6284D9A95aC57EE416Ac6309f5E48cFF9a4F4a70',
        Vesting: '0xfb712b1f8e3a036a5da44b0e8de5f93addddd126',
        StepSnap: '0xf5641f7ee02082f6cf4f62c72f7f396643480fc7',
        AuxiliaryV2: '0x5796f53758C5706A55A27352D29b8142bC026525',
        Presale: '0x17a44cce1353554301553d7fb760a6ac60a97ba7',
        MigrationV1: '0x04CD0E3b1009E8ffd9527d0591C7952D92988D0f',
        MigrationV2: '0x7071271057e4b116e7a650F7011FFE2De7C3d14b',
        Migrator: '0xfFe8666c1120Bbf58f6fD4A6B6F4d02A94C88AA3'
    }
};

// Minimal ABI for common functions - use full ABI from contract when needed
export const COFFY_ABI = CoffyCoinABI;

export const BATTLE_ABI = [
    'function createBattle(uint256 _stakeAmount, string _gameType)',
    'function joinBattle(uint256 _battleId)',
    'function getBattleInfo(uint256 battleId) view returns (address initiator, address opponent, uint256 stakeAmount, uint8 status, address winner, uint256 createdAt, uint256 commitDeadline, uint256 revealDeadline)',
    'function cancelBattle(uint256 battleId)'
];

export const AUXILIARY_ABI = AuxiliaryABI;

export const AIRDROP_ABI = [
    'function claim()',
    'function isClaimable(address user) view returns (bool)',
    'function getTimeUntilUnlock(address user) view returns (uint256)',
    'function airdrops(address) view returns (uint256 amount, uint256 unlockTime, bool claimed)'
];

export const STEPSNAP_ABI = COFFY_ABI; // StepSnap uses same ABI as CoffyCoin
