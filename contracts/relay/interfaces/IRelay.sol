// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.8.4;

interface IRelay {
    // Structures

    // Events

    /// @notice                     Emits when a block is added
    /// @param height               Height of submitted block
    /// @param merkleRoot          	Merkle root of the txs in the block
    /// @param parentMerkleRoot     Merkle root of the txs in the parent block
    /// @param relayer              Address of relayer who submitted the block data
    event BlockAdded(
        uint indexed height,
        bytes32 merkleRoot,
        bytes32 indexed parentMerkleRoot,
        address indexed relayer
    );

    /// @notice                     Emits when a block is added
    /// @param height               Height of submitted block
    /// @param merkleRoot          	Merkle root of the txs in the block
    /// @param parentMerkleRoot     Merkle root of the txs in the parent block
    /// @param relayer              Address of relayer who submitted the block data
    /// @param disputer             The address that disputed the data of this block
    event BlockVerified(
        uint indexed height,
        bytes32 indexed merkleRoot,
        bytes32 parentMerkleRoot,
        address indexed relayer,
        address disputer
    );

    /// @notice                     Emits when a block gets finalized
    /// @param height               Height of the block
    /// @param merkleRoot          	Merkle root of the txs in the block
    /// @param parentMerkleRoot     Merkle root of the txs in the parent block
    /// @param relayer              Address of relayer who submitted the block data
    /// @param rewardAmountTNT      Amount of reward that the relayer receives in target native token
    /// @param rewardAmountTDT      Amount of reward that the relayer receives in TDT
    event BlockFinalized(
        uint indexed height,
        bytes32 merkleRoot,
        bytes32 parentMerkleRoot,
        address indexed relayer,
        uint rewardAmountTNT,
        uint rewardAmountTDT
    );

    /// @notice                     Emits when a block get disputed
    /// @param merkleRoot          	Merkle root of the txs in the block
    /// @param disputer             The address that disputed the data of this block
    /// @param relayer              Address of relayer who submitted the block data
    event DisputeReward(
            bytes32 merkleRoot,
            address indexed disputer,
            address indexed relayer
    );

    /// @notice                     Emits when a block get disputed
    /// @param height               Height of the block
    /// @param merkleRoot          	Merkle root of the txs in the block
    /// @param disputer             The address that disputed the data of this block
    /// @param relayer              Address of relayer who submitted the block data
    event BlockDisputed(
            uint indexed height,
            bytes32 indexed merkleRoot,
            address disputer,
            address indexed relayer
    );

    /// @notice                     Emits when some collateral is sent back because of block removal from the storage
    /// @param height               Height of the block
    /// @param merkleRoot          	Merkle root of the txs in the block
    /// @param parentRoot           Merkle root of the parent block
    /// @param relayerOrDisputer    Address of relayer who submitted the block data
    event SentBackCollateral(
            uint indexed height,
            bytes32 indexed merkleRoot,
            bytes32 parentRoot,
            address indexed relayerOrDisputer
    );
         
    /// @notice                     Emits when changes made to reward amount in TDT
    event NewRewardAmountInTDT (uint oldRewardAmountInTDT, uint newRewardAmountInTDT);

    /// @notice                     Emits when changes made to finalization parameter
    event NewFinalizationParameter (uint oldFinalizationParameter, uint newFinalizationParameter);

    /// @notice                     Emits when changes made to relayer percentage fee
    event NewRelayerPercentageFee (uint oldRelayerPercentageFee, uint newRelayerPercentageFee);

    /// @notice                     Emits when changes made to teleportDAO token
    event NewTeleportDAOToken (address oldTeleportDAOToken, address newTeleportDAOToken);

    /// @notice                     Emits when changes made to epoch length
    event NewEpochLength(uint oldEpochLength, uint newEpochLength);

    /// @notice                     Emits when changes made to base queries
    event NewBaseQueries(uint oldBaseQueries, uint newBaseQueries);

    /// @notice                     Emits when changes made to submission gas used
    event NewSubmissionGasUsed(uint oldSubmissionGasUsed, uint newSubmissionGasUsed);

    /// @notice                     Emits when changes made to dispute time
    event NewDisputeTime(uint oldDisputeTime, uint newDisputeTime);

    /// @notice                     Emits when changes made to proof time
    event NewProofTime(uint oldProofTime, uint newProofTime);

    /// @notice                     Emits when changes made to min collateral relayer
    event NewMinCollateralRelayer(uint oldMinCollateralRelayer, uint newMinCollateralRelayer);

    /// @notice                     Emits when changes made to min collateral disputer
    event NewMinCollateralDisputer(uint oldMinCollateralDisputer, uint newMinCollateralDisputer);

    /// @notice                     Emits when changes made to dispute reward percentage
    event NewDisputeRewardPercentage(uint oldDisputeRewardPercentage, uint newDisputeRewardPercentage);

    /// @notice                     Emits when changes made to proof reward percentage
    event NewProofRewardPercentage(uint oldProofRewardPercentage, uint newProofRewardPercentage);

    // Read-only functions

    function relayGenesisMerkleRoot() external view returns (bytes32);

    function initialHeight() external view returns(uint);

    function lastVerifiedHeight() external view returns(uint);

    // function finalizationParameter() external view returns(uint);

    function TeleportDAOToken() external view returns(address);

    function relayerPercentageFee() external view returns(uint);

    function epochLength() external view returns(uint);

    function lastEpochQueries() external view returns(uint);

    function currentEpochQueries() external view returns(uint);

    function baseQueries() external view returns(uint);

    function submissionGasUsed() external view returns(uint);

    // function getBlockMerkleRoot(uint height, uint index) external view returns(bytes32);

    function getBlockUsageFee(uint _height, uint _index) external view returns(uint);

    function getNumberOfSubmittedHeaders(uint height) external view returns (uint);

    function availableTDT() external view returns(uint);

    function availableTNT() external view returns(uint);

    function findHeight(bytes32 _hash) external view returns (uint256);

    function rewardAmountInTDT() external view returns (uint);

    function minCollateralRelayer() external view returns(uint);

    function numCollateralRelayer() external view returns(uint);

    function minCollateralDisputer() external view returns(uint);
    
    function numCollateralDisputer() external view returns(uint);

    function disputeTime() external view returns(uint);

    // function proofTime() external view returns(uint); // todo: see if we need the commented params here return them in the code

    function disputeRewardPercentage() external view returns(uint);

    function proofRewardPercentage() external view returns(uint);

    function epochStartTimestamp() external view returns(uint);

    // function nonFinalizedEpochStartTimestamp(uint) external view returns(uint);

    // function currTarget() external view returns(uint);

    // function nonFinalizedCurrTarget(uint) external view returns(uint);

    // function rand(uint _height) external view returns (bytes32);

    // State-changing functions

    function pauseRelay() external;

    function unpauseRelay() external;

    function setRewardAmountInTDT(uint _rewardAmountInTDT) external;

    function setFinalizationParameter(uint _finalizationParameter) external;

    function setRelayerPercentageFee(uint _relayerPercentageFee) external;

    function setTeleportDAOToken(address _TeleportDAOToken) external;

    function setEpochLength(uint _epochLength) external;

    function setBaseQueries(uint _baseQueries) external;

    function setSubmissionGasUsed(uint _submissionGasUsed) external;

    function setDisputeTime(uint _disputeTime) external;

    function setProofTime(uint _proofTime) external;

    function setMinCollateralRelayer(uint _minCollateralRelayer) external;

    function setMinCollateralDisputer(uint _minCollateralDisputer) external;

    function setDisputeRewardPercentage(uint _disputeRewardPercentage) external;

    function setProofRewardPercentage(uint _proofRewardPercentage) external;

    function checkTxProof(
        bytes32 txid,
        uint blockHeight,
        bytes calldata intermediateNodes,
        uint index
    ) external payable returns (bool);

    function addBlock(bytes32 _anchorMerkleRoot, bytes32 _blockMerkleRoot) external payable returns (bool);

    function addBlockWithRetarget(
        bytes32 _anchorMerkleRoot, 
        bytes32 _blockMerkleRoot,
        uint256 _blockTimestamp,
        uint256 _newTarget
    ) external payable returns (bool);

    function disputeBlock(bytes32 _blockMerkleRoot) external payable returns (bool);

    function getDisputeReward(bytes32 _blockMerkleRoot) external returns (bool);

    function provideProof(bytes calldata _anchor, bytes calldata _header) external returns (bool);

    function provideProofWithRetarget(
        bytes calldata _oldPeriodEndHeader,
        bytes calldata _header
    ) external returns (bool);

    function ownerAddHeaders(bytes calldata _anchor, bytes calldata _headers) external returns (bool);

    function ownerAddHeadersWithRetarget(
        bytes calldata _oldPeriodEndHeader,
        bytes calldata _headers
    ) external returns (bool);
}