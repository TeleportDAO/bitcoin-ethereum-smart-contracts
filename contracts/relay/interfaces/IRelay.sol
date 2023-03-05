// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.8.4;

interface IRelay {
    // Structures

    /// @notice                 	Structure for recording block header
    /// @dev                        If the block header provided by the Relayer is not correct,
    ///                             it's collateral might get slashed
    /// @param selfHash             Hash of block header
    /// @param parentHash          	Hash of parent block header
    /// @param merkleRoot       	Merkle root of transactions in the block
    /// @param relayer              Address of relayer who submitted the block header
    /// @param gasPrice             Gas price of tx that relayer submitted the block header
    struct blockHeader {
        bytes32 selfHash;
        bytes32 parentHash;
        bytes32 merkleRoot;
        address relayer;
        uint gasPrice;
        bool verified;
        uint startDisputeTime;
        uint startProofTime;
        address disputer;
    }

    // todo all fn comments

    // Events

    /// @notice                     Emits when a block header is added
    /// @param height               Height of submitted header
    /// @param selfHash             Hash of submitted header
    /// @param parentHash           Parent hash of submitted header
    /// @param relayer              Address of relayer who submitted the block header
    event BlockAdded(
        uint indexed height,
        bytes32 selfHash,
        bytes32 indexed parentHash,
        address indexed relayer
    );

    /// @notice                     Emits when a block header gets finalized
    /// @param height               Height of the header
    /// @param selfHash             Hash of the header
    /// @param parentHash           Parent hash of the header
    /// @param relayer              Address of relayer who submitted the block header
    /// @param rewardAmountTNT      Amount of reward that the relayer receives in target native token
    /// @param rewardAmountTDT      Amount of reward that the relayer receives in TDT
    event BlockFinalized(
        uint indexed height,
        bytes32 selfHash,
        bytes32 parentHash,
        address indexed relayer,
        uint rewardAmountTNT,
        uint rewardAmountTDT
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

    function relayGenesisHash() external view returns (bytes32);

    function initialHeight() external view returns(uint);

    function lastVerifiedHeight() external view returns(uint);

    function finalizationParameter() external view returns(uint);

    function TeleportDAOToken() external view returns(address);

    function relayerPercentageFee() external view returns(uint);

    function epochLength() external view returns(uint);

    function lastEpochQueries() external view returns(uint);

    function currentEpochQueries() external view returns(uint);

    function baseQueries() external view returns(uint);

    function submissionGasUsed() external view returns(uint);

    function getBlockHeaderHash(uint height, uint index) external view returns(bytes32);

    function getBlockHeaderFee(uint _height, uint _index) external view returns(uint);

    function getNumberOfSubmittedHeaders(uint height) external view returns (uint);

    function availableTDT() external view returns(uint);

    function availableTNT() external view returns(uint);

    function findHeight(bytes32 _hash) external view returns (uint256);

    function findAncestor(bytes32 _hash, uint256 _offset) external view returns (bytes32); 

    function isAncestor(bytes32 _ancestor, bytes32 _descendant, uint256 _limit) external view returns (bool); 

    function rewardAmountInTDT() external view returns (uint);

    function minCollateralRelayer() external view returns(uint);

    function minCollateralDisputer() external view returns(uint);

    function disputeTime() external view returns(uint);

    function proofTime() external view returns(uint);

    function disputeRewardPercentage() external view returns(uint);

    function proofRewardPercentage() external view returns(uint);

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

    function addHeader(bytes32 _anchorHash, bytes calldata _header) external payable returns (bool);

    function disputeHeader(bytes32 _headerHash) external payable returns (bool);

    function getDisputeReward(bytes32 _headerHash) external returns (bool);

    function provideHeaderProof(bytes calldata _anchor, bytes calldata _header) external returns (bool);

    function provideHeaderProofWithRetarget(
        bytes calldata _oldPeriodStartHeader,
        bytes calldata _oldPeriodEndHeader,
        bytes calldata _header
    ) external returns (bool);
}