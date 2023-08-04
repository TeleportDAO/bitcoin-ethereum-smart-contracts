// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.8.4;

import "./BitcoinHelper.sol";
import "./TypedMemView.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

library RelayLib {

    using SafeCast for uint96;
    using SafeCast for uint256;

    using TypedMemView for bytes;
    using TypedMemView for bytes29;
    using BitcoinHelper for bytes29;

    /// @notice Structure for recording block data
    /// @dev If the block data provided by the Relayer is not correct,
    ///      it's collateral might get slashed
    /// @param merkleRoot of the txs in the block
    /// @param relayer Address of relayer who submitted the block data
    /// @param gasPrice of tx that relayer submitted the block data
    /// @param verified Whether the correctness of the block data is verified or not
    /// @param startDisputeTime When timer starts for submitting a dispute
    /// @param startProofTime When timer starts for providing the block proof
    /// @param disputer The address that disputed the data of this block
    struct blockData {
        bytes32 merkleRoot;
        address relayer;
        uint gasPrice;
        bool verified;
        uint startDisputeTime;
        uint startProofTime;
        address disputer;
    }

    /// @notice Structure for passing parameters
    /// @param proofTime  The duration in which a proof can be provided (after getiing dispute)
    /// @param currTarget The target difficulty of the current epoch
    /// @param finalizationParameter of Relay
    /// @param nonFinalizedEpochStartTimestamp Current epoch's timestamp that each new block introduces at the height of the first block in the epoch
    /// @param nonFinalizedCurrTarget New epoch's target that each new block introduces at the height of the first block in the epoch
    struct Params {
        uint proofTime;
        uint currTarget;
        uint finalizationParameter;
        uint[] nonFinalizedEpochStartTimestamp;
        uint[] nonFinalizedCurrTarget;
    }

    /// @notice Adds a Merkle root to the chain
    /// @param  _blockMerkleRoot of the new block
    /// @param  _height of the new block 
    /// @param  _messageSender address of the relayer who submitted this block
    /// @param  _chain mapping address of the chain of blocks
    function addToChain(bytes32 _blockMerkleRoot, uint _height, address _messageSender, mapping(uint => blockData[]) storage _chain) external {
        blockData memory newblockData;
        newblockData.merkleRoot = _blockMerkleRoot;
        newblockData.relayer = _messageSender;
        newblockData.gasPrice = tx.gasprice;
        newblockData.verified = false;
        newblockData.startDisputeTime = block.timestamp;
        _chain[_height].push(newblockData);
    }

    /// @notice Removes a Merkle root from the chain
    /// @param  _blockHeight of the block to be removed
    /// @param  _index of the block among the same height blocks
    /// @param  _chain Address of the chain of blocks mapping
    function removeFromChain(uint _blockHeight, uint _index, mapping(uint => blockData[]) storage _chain) external {
        _chain[_blockHeight][_index].merkleRoot = bytes32(0);
        _chain[_blockHeight][_index].relayer = address(0);
        _chain[_blockHeight][_index].gasPrice = 0;
        _chain[_blockHeight][_index].verified = false;
        _chain[_blockHeight][_index].startDisputeTime = 0;
        _chain[_blockHeight][_index].startProofTime = 0;
        _chain[_blockHeight][_index].disputer = address(0);
    }

    /// @notice Verifies the proof of correctness of a submitted block when there is no retarget
    /// @param  _anchor The block header data of the anchor block
    /// @param  _header The block header data of the new block being added
    /// @param  _chain Address of the chain of blocks mapping
    /// @param  _blockHeight Address of the block heights mapping
    /// @param  _blockHeight Address of the block heights mapping
    /// @param  _params A struct of relevant parameters
    /// @return True if successfully passed
    function provideProof(
        bytes calldata _anchor, 
        bytes calldata _header, 
        mapping(uint => blockData[]) storage _chain, 
        mapping(bytes32 => uint256) storage _blockHeight, 
        mapping(bytes32 => bytes32) storage _parentRoot,
        Params memory _params
    ) external view returns(bool){
        bytes29 _headerView = _header.ref(0).tryAsHeader();
        bytes29 _anchorView = _anchor.ref(0).tryAsHeader();
        _checkInputSize(_headerView, _anchorView);
        return _checkHeaderProof(_anchorView, _headerView, false, _chain, _blockHeight, _parentRoot, _params);
    }

    /// @notice Verifies the proof of correctness of a submitted block when there is no retarget
    /// @param  _anchor The block header data of the anchor block
    /// @param  _header The block header data of the new block being added
    /// @param  _chain Address of the chain of blocks mapping
    /// @param  _blockHeight Address of the block heights mapping
    /// @param  _parentRoot Address of the parent block root mapping
    /// @param  _params A struct of relevant parameters
    /// @param  _epochStartTimestamp Current epoch's first block timestamp
    /// @return True if successfully passed
    function provideProofWithRetarget(
        bytes calldata _anchor, 
        bytes calldata _header, 
        mapping(uint => blockData[]) storage _chain, 
        mapping(bytes32 => uint256) storage _blockHeight, 
        mapping(bytes32 => bytes32) storage _parentRoot,
        Params memory _params,
        uint _epochStartTimestamp
    ) external view returns(bool){
        bytes29 _anchorView = _anchor.ref(0).tryAsHeader();
        bytes29 _headerView = _header.ref(0).tryAsHeader();
        _checkInputSize(_anchorView, _headerView);

        uint256 _anchorHeight = _findHeight(_anchorView.merkleRoot(), _blockHeight);
        checkEpochEndBlock(_anchor, _anchorHeight, _params.currTarget);
        checkRetarget(_anchorView.time(), _params.currTarget, _headerView.target(), _epochStartTimestamp);
        return _checkHeaderProof(_anchorView, _headerView, true, _chain, _blockHeight, _parentRoot, _params);
    }

    /// @notice Internal function for provideProof
    function _checkHeaderProof(
        bytes29 _anchor,
        bytes29 _header,
        bool _withRetarget,
        mapping(uint => blockData[]) storage _chain, 
        mapping(bytes32 => uint256) storage _blockHeight, 
        mapping(bytes32 => bytes32) storage _parentRoot,
        Params memory _params
    ) private view returns(bool) {
        /*
            1. Check block is not verified yet & proof time not passed
            2. Match the stored data with provided data: parent merkle root
            3. Check the provided timestamp and target are correct
            4. Checks the proof validity: no retarget & hash link good & enough PoW
            5. Mark the header as verified and give back the collateral to relayer
        */

        uint _idx = _checkProofCanBeProvided(_header.merkleRoot(), _blockHeight, _chain, _params.proofTime);
        _checkStoredDataMatch(_anchor.merkleRoot(), _header.merkleRoot(), _parentRoot);
        if(_withRetarget) {
            require(
                _params.nonFinalizedEpochStartTimestamp[_idx] == _header.time(),
                "RelayLib: incorrect timestamp"
            );
            require(
                _params.nonFinalizedCurrTarget[_idx] == _header.target(),
                "RelayLib: incorrect target"
            );
        }
        _checkProofValidity(_anchor, _header, _withRetarget, _parentRoot, _chain, _blockHeight, _params);

        return true;
    }

    /// @notice Checks the provided proof's correctness in terms of the Bitcoin consensus mechanism
    /// @dev Can verify multiple headers at once
    function checkProofValidity(
        bytes calldata _anchor, 
        bytes calldata _headers, 
        bool _withRetarget,
        mapping(bytes32 => bytes32) storage _parentRoot,
        mapping(uint => blockData[]) storage _chain,
        mapping(bytes32 => uint256) storage _blockHeight, 
        Params memory _params,
        uint headerIdx
    ) external view {
        bytes29 _anchorView;
        bytes29 _headerView = _headers.ref(0).tryAsHeaderArray().indexHeaderArray(headerIdx);
        if (headerIdx == 0) {
            _anchorView = _anchor.ref(0).tryAsHeader();
        } else {
            _anchorView = _headers.ref(0).tryAsHeaderArray().indexHeaderArray(headerIdx - 1);
        }
        _checkProofValidity(_anchorView, _headerView, ((headerIdx == 0)? _withRetarget : false), _parentRoot, _chain, _blockHeight, _params);
    }

    /// @notice check that new target complies with the retarget algorithm
    function checkRetarget(
        uint256 _epochEndTimestamp, 
        uint256 _oldEndTarget, 
        uint256 _actualTarget, 
        uint256 epochStartTimestamp
    ) public pure {
        /* NB: This comparison looks weird because header nBits encoding truncates targets */
        uint256 _expectedTarget = BitcoinHelper.retargetAlgorithm(
            _oldEndTarget,
            epochStartTimestamp,
            _epochEndTimestamp
        );
        require(
            (_actualTarget & _expectedTarget) == _actualTarget, 
            "RelayLib: invalid retarget"
        );
    }

    /// @notice Checks the target related data for the last block of the epoch be correct
    /// @dev In library func for _checkEpochEndBlock
    function checkEpochEndBlock(bytes calldata _oldPeriodEndHeader, uint256 _endHeight, uint currTarget) public view {
        bytes29 _oldEnd = _oldPeriodEndHeader.ref(0).tryAsHeader();
        // Retargets should happen at 2016 block intervals
        require(
            _endHeight % BitcoinHelper.RETARGET_PERIOD_BLOCKS == 2015,
            "RelayLib: wrong end height"
        );
        // Block time should not be unreasonably large
        require(
            _oldEnd.time() < block.timestamp + 2 hours,
            "RelayLib: anchor time incorrect"
        );
        // Checks that the header has sufficient work
        require(
            TypedMemView.reverseUint256(uint256(_oldEnd.hash256())) <= currTarget,
            "RelayLib: insufficient work for anchor"
        ); 
    }

    /// @notice checkValidityProof internal function that verifies one header at a time
    /// @dev Checks that _anchor is parent of _header and it has sufficient PoW
    function _checkProofValidity(
        bytes29 _anchor, 
        bytes29 _header, 
        bool _withRetarget,
        mapping(bytes32 => bytes32) storage _parentRoot,
        mapping(uint => blockData[]) storage _chain,
        mapping(bytes32 => uint256) storage _blockHeight, 
        Params memory _params
    ) private view {
        // Extracts basic info
        uint _height = _findHeight(_anchor.merkleRoot(), _blockHeight) + 1; // Reverts if the header doesn't exist
        uint256 _target = _header.target();
        uint _idxInEpoch = _height % BitcoinHelper.RETARGET_PERIOD_BLOCKS;

        // Checks targets are same in the case of no-retarget
        require(
            _withRetarget || _anchor.target() == _target,
            "RelayLib: unexpected retarget"
        );

        // check the target matches the storage
        if(
            !_withRetarget &&
            _idxInEpoch <= _params.finalizationParameter &&
            _params.nonFinalizedCurrTarget.length != 0
        ) {
            // check _target matches with its ancestor's saved target in nonFinalizedCurrTarget
            require(
                _params.nonFinalizedCurrTarget[_findIndex(_findAncestor(_header.merkleRoot(), _idxInEpoch, _parentRoot), _height - _idxInEpoch, _chain)]
                == _target,
                "RelayLib: targets do not match"
            );
        } else {
            require(
                _withRetarget || (_params.currTarget & _target) == _target, // TODO remove &?
                "RelayLib: wrong target"
            );
        }

        // Blocks that are multiplies of 2016 should be submitted using provideProofWithRetarget
        require(
            _withRetarget || _idxInEpoch != 0,
            "RelayLib: wrong func"
        );

        // Checks previous block link is correct
        require(
            _header.checkParent(_anchor.hash256()), 
            "RelayLib: no link"
        );
        
        // Checks that the header has sufficient work
        require(
            TypedMemView.reverseUint256(uint256(_header.hash256())) <= _target,
            "RelayLib: insufficient work"
        );
    }

    /// @notice                 Checks the size of addHeader inputs 
    /// @param  _headerView1    Input to the provideProof functions
    /// @param  _headerView2    Input to the provideProof functions
    function _checkInputSize(bytes29 _headerView1, bytes29 _headerView2) private pure {
        require(
            _headerView1.notNull() && _headerView2.notNull(),
            "RelayLib: bad args. Check header and array byte lengths."
        );
    }

    /// @notice Finds index of Merkle root in a specific height
    /// @param  _blockMerkleRoot Desired Merkle root
    /// @param  _height of Merkle root
    /// @return _index If the header exists: its index, if not revert
    function _findIndex(bytes32 _blockMerkleRoot, uint _height, mapping(uint => blockData[]) storage _chain) private view returns (uint _index) {
        for (_index = 0; _index < _chain[_height].length; _index++) {
            if(_blockMerkleRoot == _chain[_height][_index].merkleRoot) {
                return _index;
            }
        }
        require(false, "RelayLib: unknown block");
    }

    /// @notice             Finds the height of a header by its hash
    /// @dev                Will fail if the header is unknown
    /// @param _hash        The header hash to search for
    /// @return             The height of the header
    function _findHeight(bytes32 _hash, mapping(bytes32 => uint256) storage _blockHeight) private view returns (uint256) {
        if (_blockHeight[_hash] == 0) {
            revert("RelayLib: unknown block");
        }
        else {
            return _blockHeight[_hash];
        }
    }

    /// @notice Check the conditions needed to be met for being able to provide a proof
    function _checkProofCanBeProvided(
        bytes32 _blockMerkleRoot, 
        mapping(bytes32 => uint256) storage _blockHeight, 
        mapping(uint => blockData[]) storage _chain, 
        uint _proofTime
    ) private view returns(uint) {
        uint _height = _findHeight(_blockMerkleRoot, _blockHeight); // Revert if the block is unknown
        uint _idx = _findIndex(_blockMerkleRoot, _height, _chain);
        // Should not been verified before
        require(!_chain[_height][_idx].verified, "RelayLib: already verified");
        // Proof time should not passed
        require(
            (_isDisputed(_chain[_height][_idx].disputer) && !_proofTimePassed(_chain[_height][_idx].startProofTime, _proofTime))
                || !_isDisputed(_chain[_height][_idx].disputer),
            "RelayLib: proof time passed"
        );
        return _idx;
    }

    /// @notice Returns true if Merkle root got disputed
    function _isDisputed(address _disputer) private pure returns (bool) {
        return (_disputer == address(0)) ? false : true;
    }

    /// @notice Returns true if proof time is passed
    function _proofTimePassed(uint _startProofTime, uint _proofTime) private view returns (bool) {
        return (block.timestamp - _startProofTime >= _proofTime) ? true : false;
    }

    /// @notice check the provided parent Merkle root matches the storage
    function _checkStoredDataMatch(bytes32 _anchorMerkleRoot, bytes32 _blockMerkleRoot, mapping(bytes32 => bytes32) storage _parentRoot) private view {
        // Checks parent merkle root matches
        require(
            _anchorMerkleRoot == _parentRoot[_blockMerkleRoot], 
            "RelayLib: not match"
        );
    }

    // @notice              Finds an ancestor for a block by its merkle root
    /// @dev                Will fail if the header is unknown
    /// @param _merkleRoot  The header merkle root to search for
    /// @param _offset      The depth which is going to be searched
    /// @return             The height of the header, or error if unknown
    function _findAncestor(bytes32 _merkleRoot, uint256 _offset, mapping(bytes32 => bytes32) storage _parentRoot) private view returns (bytes32) {
        bytes32 _current = _merkleRoot;
        for (uint256 i = 0; i < _offset; i++) {
            _current = _parentRoot[_current];
        }
        require(_current != bytes32(0), "RelayLib: unknown ancestor");
        return _current;
    }
}