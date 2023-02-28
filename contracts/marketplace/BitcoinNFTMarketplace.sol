// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.8.4;

import "./interfaces/IBitcoinNFTMarketplace.sol";
import "../relay/interfaces/IBitcoinRelay.sol";
import "../libraries/BitcoinHelper.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hardhat/console.sol";

contract BitcoinNFTMarketplace is IBitcoinNFTMarketplace, Ownable, ReentrancyGuard {

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "CCBurnRouter: address is zero");
        _;
    }

    constructor(address _relay, uint _transferDeadline) {
        setRelay(_relay);
        setTransferDeadline(_transferDeadline);
    }

    address public override relay;
    uint public override transferDeadline;
    bytes1 constant private FOUR = 0x04;
    
    mapping(bytes32 => mapping(address => NFT)) public nfts; // mapping from [txId][seller] to listed NFT
    mapping(bytes32 => mapping(address => Bid[])) public bids; // mapping from [txId][seller] to listed NFT (note: it wasn't possible to define Bid[] in NFT)

    /// @notice Internal setter for relay contract address
    /// @param _relay The new relay contract address
    function setRelay(address _relay) public override nonZeroAddress(_relay) {
        relay = _relay;
    }

    /// @notice Internal setter for deadline of sending NFT
    /// @dev Deadline should be greater than relay finalization parameter
    /// @param _transferDeadline The new transfer deadline
    function setTransferDeadline(uint _transferDeadline) public override {
        uint _finalizationParameter = IBitcoinRelay(relay).finalizationParameter();
        // gives seller enough time to send nft
        require(_transferDeadline > _finalizationParameter * 2, "Marketplace: low deadline");
        transferDeadline = _transferDeadline;
    }
    
    /// @notice Lists NFT of a user
    /// @dev User should sign the txId of the NFT with the same private key that holds the NFT
    /// @param _bitcoinPubKey Bitcoin PubKey of the NFT holder (without starting '04')
    /// @param _scriptType Type of the account that holds the NFT
    /// @param _r Part of signature of _bitcoinPubKey for the txId
    /// @param _s Part of signature of _bitcoinPubKey for the txId
    /// @param _v is needed for recovering the public key (it can be 27 or 28)
    /// @param _tx Transaction that includes the NFT
    /// @param _outputIdx Index of the output that includes NFT
    /// @param _satoshiIdx Index of the inscribed satoshi in the output satoshis
    function listNFT(
        bytes memory _bitcoinPubKey,
        ScriptTypes _scriptType,
        bytes32 _r,
        bytes32 _s,
        uint8 _v,
        Tx memory _tx,
        uint _outputIdx,
		uint _satoshiIdx
	) external override returns (bool) {
        require(_bitcoinPubKey.length == 64, "invalid pub key");
        bytes32 txId = BitcoinHelper.calculateTxId(_tx.version, _tx.vin, _tx.vout, _tx.locktime);
        
        // extract locking script from the output that includes the NTF
        bytes memory lockingScript = BitcoinHelper.getLockingScript(_tx.vout, _outputIdx);

        if (_scriptType == ScriptTypes.P2WPKH) { // locking script = ZERO (1 byte) PUB_KEY_HASH (20 bytes)
            require(
                _compareBytes(
                    _sliceBytes(lockingScript, 1, 40), _doubleHash(abi.encodePacked(FOUR, _bitcoinPubKey))
                ),
                "Marketplace: wrong pub key"
            );
        } else if (_scriptType == ScriptTypes.P2PKH) { // locking script = OP_DUP (1 byte) OP_HASH160 (2 bytes) PUB_KEY_HASH (20 bytes)  OP_EQUALVERIFY OP_CHECKSIG
            require(
                _compareBytes(
                    _sliceBytes(lockingScript, 3, 22), _doubleHash(abi.encodePacked(FOUR, _bitcoinPubKey))
                ),
                "Marketplace: wrong pub key"
            );
        } else if (_scriptType == ScriptTypes.P2PK) { // locking script = PUB_KEY (65 bytes) OP_CHECKSIG
            require(
                _compareBytes(
                    _sliceBytes(lockingScript, 0, 64), abi.encodePacked(FOUR, _bitcoinPubKey)
                ),
                "Marketplace: wrong pub key"
            );
        } else {
            revert("Marketplace: invalid type");
        }

        // check that the signature for txId is valid
        // etherum address = last 20 bytes of hash(pubkey)
        require(
            _bytesToAddress(_sliceBytes(abi.encodePacked(keccak256(_bitcoinPubKey)), 12, 31)) == 
                ecrecover(txId, _v, _r, _s),
            "Marketplace: not nft owner"
        );

        // store NFT
        NFT memory _nft;
        _nft.outputIdx = _outputIdx;
        _nft.satoshiIdx = _satoshiIdx;
        nfts[txId][_msgSender()] = _nft;

        emit NFTListed(txId, _outputIdx, _satoshiIdx, _msgSender());

        return true;
    }


    /// @notice Puts bid for buyying an NTF
    /// @dev User sends the bid amount along with the request
    /// @param _txId of the NFT
    /// @param _seller Address of the seller
    /// @param _buyerBTCScript Seller will send the NFT to the provided script (it doesn't include op_codes)
    /// @param _scriptType Type of the script
    function putBid(
        bytes32 _txId,
        address _seller, 
        bytes memory _buyerBTCScript,
        ScriptTypes _scriptType
    ) external payable override returns (bool) {
        require(!nfts[_txId][_seller].isSold, "Marketplace: sold nft");
        // check that the script is valid 
        _checkScriptType(_buyerBTCScript, _scriptType);

        // store bid
        Bid memory _bid;
        _bid.buyerBTCScript =  _buyerBTCScript;
        _bid.buyerScriptType =  _scriptType;
        _bid.buyerETHAddress = _msgSender();
        _bid.bidAmount = msg.value;
        bids[_txId][_seller].push(_bid);

        return true;
    }

    /// @notice Removes buyer's bid
    /// @dev Buyers can withdraw their funds after deadline 
    ///      (deadline is 0 for a non-accepted bid, so they can withdaw at any time)
    /// @dev Only bid owner can call this function
    /// @param _txId of the NFT
    /// @param _seller Address of the seller
    /// @param _bidIdx Index of the bid in bids list
    function revokeBid(
        bytes32 _txId, 
        address _seller,
        uint _bidIdx
    ) external override returns (bool) {
        require(
            bids[_txId][_seller][_bidIdx].buyerETHAddress == _msgSender(),
            "Marketplace: not owner"
        );

        // handle the case where the seller accepted a bid but didn't transfer NFT to the buyer before the deadline
        if (bids[_txId][_seller][_bidIdx].isAccepted) {
            // check that deadline is passed but nft hasn't been transffered
            require(!nfts[_txId][_seller].isSold, "Marketplace: nft sold");
            require(
                IBitcoinRelay(relay).lastSubmittedHeight() > bids[_txId][_seller][_bidIdx].deadline,
                "Marketplace: deadline not passed"
            );
            // change the status of the NFT (so seller can accept a new bid)
            nfts[_txId][_seller].hasAccepted = false;
        }

        // send ETH to buyer
        Address.sendValue(payable(_msgSender()), bids[_txId][_seller][_bidIdx].bidAmount);

        // delete bid
        delete bids[_txId][_seller][_bidIdx];

        return true;
    }

    /// @notice Accepts one of the existing bids
    /// @dev Will be reverted if the seller has already accepted a bid
    /// @param _txId of the NFT
    /// @param _bidIdx Index of the bid in bids list
    function acceptBid(bytes32 _txId, uint _bidIdx) external override returns (bool) {
        require(!nfts[_txId][_msgSender()].hasAccepted, "Marketplace: already accepted"); 
        nfts[_txId][_msgSender()].hasAccepted = true;
        // seller has a limited time to send the NFT and provide a proof for it to get it
        bids[_txId][_msgSender()][_bidIdx].isAccepted = true;
        bids[_txId][_msgSender()][_bidIdx].deadline = IBitcoinRelay(relay).lastSubmittedHeight() + transferDeadline;

        return true;
    }

    /// @notice Sends ETH to seller after checking the proof of transfer
    /// @param _txId of the NFT
    /// @param _seller Address of the seller
    /// @param _bidIdx Index of the accepted bid in bids list
    /// @param _transferTx transaction that transffred NFT from seller to buyer
    /// @param _outputNFTIdx Index of output that includes NFT
    /// @param _blockNumber Height of the block containing _transferTx
    /// @param _intermediateNodes Merkle inclusion proof for _transferTx
    /// @param _index Index of _transferTx in the block
    /// @param _inputTxs List of all transactions that were spent by _transferTx before the input that spent the NFT
    function sellNFT(
        bytes32 _txId,
        address _seller,
        uint _bidIdx,
        Tx memory _transferTx,
        uint _outputNFTIdx,
    	uint256 _blockNumber,
		bytes memory _intermediateNodes,
		uint _index,
        Tx[] memory _inputTxs
    ) external override returns (bool) {
        // check inclusion of transfer tx
        _isConfirmed(
            BitcoinHelper.calculateTxId(
                _transferTx.version, 
                _transferTx.vin, 
                _transferTx.vout, 
                _transferTx.locktime
            ),
            _blockNumber,
            _intermediateNodes,
            _index
        );

        // find the index of NFT satoshi
        uint nftIdx;
        nftIdx = _nftIdx(_txId, _seller,  _transferTx.vin, _inputTxs);

        // check that weather the NFT is transferred to the expected buyer or not
        _checkNFTTransfer(_txId, _seller, _bidIdx, _transferTx.vout, _outputNFTIdx, nftIdx);

        // send ETH to seller
        Address.sendValue(payable(_seller), bids[_txId][_seller][_bidIdx].bidAmount);

        return true;
    }

    function _checkScriptType(bytes memory _script, ScriptTypes _scriptType) private pure {
        if (_scriptType == ScriptTypes.P2PK || _scriptType == ScriptTypes.P2WSH) {
            require(_script.length == 32, "Marketplace: invalid script");
        } else {
            require(_script.length == 20, "Marketplace: invalid script");
        }
    }

    /// @notice Finds the index of NFT in the input of transfer tx
    /// @param _txId of the NFT
    /// @param _seller Address of the seller
    /// @param _vin inputs of transaction that transffred NFT from seller to buyer
    /// @param _inputTxs List of all transactions that were spent by _transferTx before the input that spent the NFT
    function _nftIdx(
        bytes32 _txId,
        address _seller,
        bytes memory _vin,
        Tx[] memory _inputTxs
    ) internal view returns (uint _idx) {
        bytes32 _outpointId;
        uint _outpointIndex;

        // calculate sum of all the provided inputs in transferTx (before input that spent NFT)
        for (uint i = 0; i < _inputTxs.length; i++) {
            (_outpointId, _outpointIndex) = BitcoinHelper.extractOutpoint(
                _vin,
                i
            );

            // check that "outpoint tx id == input tx id"
            // make sure that the provided input txs are valid
            require(
                _outpointId == BitcoinHelper.calculateTxId(
                    _inputTxs[i].version, 
                    _inputTxs[i].vin, 
                    _inputTxs[i].vout, 
                    _inputTxs[i].locktime
                ),
                "Marketplace: outpoint != input tx"
            );

            // sum of all inputs of transfer tx before the input that spent NFT
            _idx += BitcoinHelper.parseOutputValue(_inputTxs[i].vout, _outpointIndex);
        }

        (_outpointId, _outpointIndex) = BitcoinHelper.extractOutpoint(
            _vin,
            _inputTxs.length + 1 // this is the input that spent the NFT
        );

        // Checks that "outpoint tx id == _txId"
        require(
            (_outpointId == _txId) && (_outpointIndex == nfts[_txId][_seller].outputIdx),
            "Marketplace: outpoint not match with _txId"
        );

        // find the positon of NFT satoshi in input of transfer tx
        _idx += nfts[_txId][_seller].satoshiIdx;
    }

    /// @notice Checks that weather the NFT is transffered to buyer or not
    /// @param _txId of the NFT
    /// @param _seller Address of the seller
    /// @param _bidIdx Index of the accepted bid in bids list
    /// @param _vout output of transaction that transffred NFT from seller to buyer
    /// @param _outputNFTIdx Index of output that includes NFT
    /// @param _nftIdxInput Index of satoshi NFT in input of tx
    function _checkNFTTransfer(
        bytes32 _txId,
        address _seller,
        uint _bidIdx,
        bytes memory _vout,
        uint _outputNFTIdx,
        uint _nftIdxInput
    ) internal {
        // find number of satoshis before the output that includes the NFT
        uint outputValue;
        for (uint i = 0; i < _outputNFTIdx; i++) {
            outputValue += BitcoinHelper.parseOutputValue(_vout, i);
        }

        require(
            _nftIdxInput > outputValue && 
            _nftIdxInput < outputValue + BitcoinHelper.parseValueFromSpecificOutputHavingScript(
                _vout,
                _outputNFTIdx,
                bids[_txId][_seller][_bidIdx].buyerBTCScript,
                bids[_txId][_seller][_bidIdx].buyerScriptType
            ),
            "Marketplace: not transffered"
        );

        nfts[_txId][_seller].isSold = true;
    }

    /// @notice Checks inclusion of the transaction in the specified block
    /// @dev Calls the relay contract to check Merkle inclusion proof
    /// @param _txId Id of the transaction
    /// @param _blockNumber Height of the block containing the transaction
    /// @param _intermediateNodes Merkle inclusion proof for the transaction
    /// @param _index Index of transaction in the block
    /// @return True if the transaction was included in the block
    function _isConfirmed(
        bytes32 _txId,
        uint256 _blockNumber,
        bytes memory _intermediateNodes,
        uint _index
    ) private returns (bool) {
        // Finds fee amount
        uint feeAmount = IBitcoinRelay(relay).getBlockHeaderFee(_blockNumber, 0);
        require(msg.value >= feeAmount, "Marketplace: relay fee is not sufficient");

        // Calls relay contract
        bytes memory data = Address.functionCallWithValue(
            relay,
            abi.encodeWithSignature(
                "checkTxProof(bytes32,uint256,bytes,uint256)",
                _txId,
                _blockNumber,
                _intermediateNodes,
                _index
            ),
            feeAmount
        );

        // Sends extra ETH back to _msgSender()
        Address.sendValue(payable(_msgSender()), msg.value - feeAmount);

        return abi.decode(data, (bool));
    }

    /// @notice                 Returns a sliced bytes
    /// @param _data            Data that is sliced
    /// @param _start           Start index of slicing
    /// @param _end             End index of slicing
    /// @return _result         The result of slicing
    function _sliceBytes(
        bytes memory _data,
        uint _start,
        uint _end
    ) internal pure returns (bytes memory _result) {
        bytes1 temp;
        for (uint i = _start; i <= _end; i++) {
            temp = _data[i];
            _result = abi.encodePacked(_result, temp);
        }
    }

    // bitcoin double hash function
    function _doubleHash(bytes memory input) internal pure returns(bytes memory) {
        bytes32 inputHash1 = sha256(input);
        bytes20 inputHash2 = ripemd160(abi.encodePacked(inputHash1));
        return abi.encodePacked(inputHash2);
    }

    function _compareBytes(bytes memory _a, bytes memory _b) internal pure returns (bool) {
        return keccak256(_a) == keccak256(_b);
    }

    function _bytesToAddress(bytes memory _data) public pure returns (address) {
        require(_data.length == 20, "Invalid address length");
        address addr;
        assembly {
            addr := mload(add(_data, 20))
        }
        return addr;
    }
}