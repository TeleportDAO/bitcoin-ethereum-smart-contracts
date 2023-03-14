// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.8.4;

import "./interfaces/IBitcoinNFTMarketplace.sol";
import "../relay/interfaces/IBitcoinRelay.sol";
import "../libraries/BitcoinHelper.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "hardhat/console.sol";

contract BitcoinNFTMarketplace is IBitcoinNFTMarketplace, Ownable, ReentrancyGuard, Pausable {

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "BitcoinNFTMarketplace: address is zero");
        _;
    }

    constructor(
        address _relay, 
        uint _transferDeadline, 
        uint _protocolFee,
        address _treasury,
        bool _isSignRequired
    ) {
        setRelay(_relay);
        setTransferDeadline(_transferDeadline);
        setProtocolFee(_protocolFee);
        setTreasury(_treasury);
        setIsSignRequired(_isSignRequired);
    }

    address public override relay;
    bool public override isSignRequired;
    uint public override transferDeadline;
    uint public override protocolFee;
    address public override treasury;
    bytes1 constant private FOUR = 0x04;
    uint constant public MAX_PROTOCOL_FEE = 10000; // 10000 = %100
    uint256 constant public Q = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141; // secp256k1 group order
    
    mapping(bytes32 => mapping(address => NFT)) public nfts; // mapping from [txId][seller] to listed NFT
    mapping(bytes32 => mapping(address => Bid[])) public bids; // mapping from [txId][seller] to listed NFT (note: it wasn't possible to define Bid[] in NFT)

    receive() external payable {}
    
    /// @notice Setter for relay contract address
    /// @param _relay The new relay contract address
    function setRelay(address _relay) public override nonZeroAddress(_relay) onlyOwner {
        relay = _relay;
    }

    /// @notice Setter for treasury address
    /// @param _treasury The new treasury address
    function setTreasury(address _treasury) public override nonZeroAddress(_treasury) onlyOwner {
        treasury = _treasury;
    }

    /// @notice Setter for deadline of sending NFT
    /// @dev Deadline should be greater than relay finalization parameter
    /// @param _transferDeadline The new transfer deadline
    function setTransferDeadline(uint _transferDeadline) public override onlyOwner {
        uint _finalizationParameter = IBitcoinRelay(relay).finalizationParameter();
        // gives seller enough time to send nft
        require(_transferDeadline > _finalizationParameter * 2, "BitcoinNFTMarketplace: low deadline");
        transferDeadline = _transferDeadline;
    }

    /// @notice Setter for protocol fee
    /// @param _protocolFee The new protocol fee
    function setProtocolFee(uint _protocolFee) public override onlyOwner {
        require(MAX_PROTOCOL_FEE >= _protocolFee, "BitcoinNFTMarketplace: invalid fee");
        protocolFee = _protocolFee;
    }

    /// @notice Setter for signing requirements
    /// @param _isSignRequired new requirements
    function setIsSignRequired(bool _isSignRequired) public override onlyOwner {
        isSignRequired = _isSignRequired;
    }

    /// @notice Pause the contract so only the functions can be called which are whenPaused
    /// @dev Only owner can pause 
    function pause() external override onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract so only the functions can be called which are whenNotPaused
    /// @dev Only owner can pause
    function unpause() external override onlyOwner {
        _unpause();
    }

    function renounceOwnership() public virtual override onlyOwner {}
    
    /// @notice Lists NFT of a user
    /// @dev User should sign the txId of the NFT with the same private key that holds the NFT if isSignRequired is true
    /// @param _bitcoinPubKey Bitcoin PubKey of the NFT holder (without starting '04'). Don't need to be passed in the case of Taproot
    /// @param _scriptType Type of the account that holds the NFT
    /// @param _r Part of signature of _bitcoinPubKey for the txId (or `e` challenge for schnorr sig)
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
	) external override whenNotPaused returns (bool) {
        bytes32 txId = BitcoinHelper.calculateTxId(_tx.version, _tx.vin, _tx.vout, _tx.locktime);
        require(!nfts[txId][_msgSender()].isListed, "BitcoinNFTMarketplace: already listed");

        // if isSignRequired, seller should provide a valid signature to list NFT (with the same public key that holds the NFT)
        if (isSignRequired) {
            require(_bitcoinPubKey.length == 64 || _bitcoinPubKey.length == 0, "invalid pub key"); // 0 for taproot, 64 for other cases
            // extract locking script from the output that includes the NTF
            bytes memory lockingScript = BitcoinHelper.getLockingScript(_tx.vout, _outputIdx);
            if (_scriptType == ScriptTypes.P2TR) { // locking script = OP_1 (1 byte) 20 (1 byte) PUB_KEY (32 bytes)
                require(
                    _verifySchnorr(_convertToBytes32(_sliceBytes(lockingScript, 2, 33)), txId, _r, _s, _v),
                    "BitcoinNFTMarketplace: not nft owner"
                );
            } else {
                if (_scriptType == ScriptTypes.P2WPKH) { // locking script = ZERO (1 byte) PUB_KEY_HASH (20 bytes)
                    require(
                        _compareBytes(
                            _sliceBytes(lockingScript, 1, 40), _doubleHash(abi.encodePacked(FOUR, _bitcoinPubKey))
                        ),
                        "BitcoinNFTMarketplace: wrong pub key"
                    );
                } else if (_scriptType == ScriptTypes.P2PKH) { // locking script = OP_DUP (1 byte) OP_HASH160 (2 bytes) PUB_KEY_HASH (20 bytes)  OP_EQUALVERIFY OP_CHECKSIG
                    require(
                        _compareBytes(
                            _sliceBytes(lockingScript, 3, 22), _doubleHash(abi.encodePacked(FOUR, _bitcoinPubKey))
                        ),
                        "BitcoinNFTMarketplace: wrong pub key"
                    );
                } else if (_scriptType == ScriptTypes.P2PK) { // locking script = PUB_KEY (65 bytes) OP_CHECKSIG
                    require(
                        _compareBytes(
                            _sliceBytes(lockingScript, 0, 64), abi.encodePacked(FOUR, _bitcoinPubKey)
                        ),
                        "BitcoinNFTMarketplace: wrong pub key"
                    );
                } else {
                    revert("BitcoinNFTMarketplace: invalid type");
                }

                // check that the signature for txId is valid
                // etherum address = last 20 bytes of hash(pubkey)
                require(
                    _bytesToAddress(_sliceBytes(abi.encodePacked(keccak256(_bitcoinPubKey)), 12, 31)) == 
                        ecrecover(txId, _v, _r, _s),
                    "BitcoinNFTMarketplace: not nft owner"
                );
            }
        }

        // store NFT
        NFT memory _nft;
        _nft.outputIdx = _outputIdx;
        _nft.satoshiIdx = _satoshiIdx;
        _nft.isListed = true;
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
    ) external payable whenNotPaused override returns (bool) {
        require(!nfts[_txId][_seller].isSold, "BitcoinNFTMarketplace: sold nft");
        // check that the script is valid 
        _checkScriptType(_buyerBTCScript, _scriptType);

        // store bid
        Bid memory _bid;
        _bid.buyerBTCScript =  _buyerBTCScript;
        _bid.buyerScriptType =  _scriptType;
        _bid.buyerETHAddress = _msgSender();
        _bid.bidAmount = msg.value;
        bids[_txId][_seller].push(_bid);
        uint bidIdx = bids[_txId][_seller].length - 1;

        emit NewBid(
            _txId, 
            nfts[_txId][_seller].outputIdx,
            nfts[_txId][_seller].satoshiIdx,
            _seller, 
            _msgSender(),
            _buyerBTCScript,
            _scriptType,
            msg.value,
            bidIdx
        );

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
    ) external nonReentrant override returns (bool) {
        require(
            bids[_txId][_seller][_bidIdx].buyerETHAddress == _msgSender(),
            "BitcoinNFTMarketplace: not owner"
        );

        // handle the case where the seller accepted a bid but didn't transfer NFT to the buyer before the deadline
        if (bids[_txId][_seller][_bidIdx].isAccepted) {
            // check that deadline is passed but nft hasn't been transffered
            require(!nfts[_txId][_seller].isSold, "BitcoinNFTMarketplace: nft sold");
            require(
                IBitcoinRelay(relay).lastSubmittedHeight() > bids[_txId][_seller][_bidIdx].deadline,
                "BitcoinNFTMarketplace: deadline not passed"
            );
            // change the status of the NFT (so seller can accept a new bid)
            nfts[_txId][_seller].hasAccepted = false;
        }

        // send ETH to buyer
        Address.sendValue(payable(_msgSender()), bids[_txId][_seller][_bidIdx].bidAmount);

        // delete bid
        delete bids[_txId][_seller][_bidIdx];

        emit BidRevoked(_txId, _seller, _bidIdx);

        return true;
    }

    /// @notice Accepts one of the existing bids
    /// @dev Will be reverted if the seller has already accepted a bid
    /// @param _txId of the NFT
    /// @param _bidIdx Index of the bid in bids list
    function acceptBid(bytes32 _txId, uint _bidIdx) external nonReentrant whenNotPaused override returns (bool) {
        require(!nfts[_txId][_msgSender()].hasAccepted, "BitcoinNFTMarketplace: already accepted");
        require(bids[_txId][_msgSender()].length > _bidIdx, "BitcoinNFTMarketplace: invalid idx");  

        // seller has a limited time to send the NFT and provide a proof for it to get it
        nfts[_txId][_msgSender()].hasAccepted = true;
        bids[_txId][_msgSender()][_bidIdx].isAccepted = true;
        bids[_txId][_msgSender()][_bidIdx].deadline = IBitcoinRelay(relay).lastSubmittedHeight() + transferDeadline;

        emit BidAccepted(
            _txId, 
            _msgSender(),
            _bidIdx, 
            bids[_txId][_msgSender()][_bidIdx].deadline
        );

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
    ) external payable nonReentrant whenNotPaused override returns (bool) {
        // checks that NFT hasn't been sold before
        require(!nfts[_txId][_seller].isSold, "BitcoinNFTMarketplace: sold nft");

        // check inclusion of transfer tx
        bytes32 transferTxId = BitcoinHelper.calculateTxId(
            _transferTx.version, 
            _transferTx.vin, 
            _transferTx.vout, 
            _transferTx.locktime
        );
        require(
            _isConfirmed(
                transferTxId,
                _blockNumber,
                _intermediateNodes,
                _index
            ),
            "BitcoinNFTMarketplace: not finalized"
        );

        // find the index of NFT satoshi
        uint nftIdx;
        nftIdx = _nftIdx(_txId, _seller,  _transferTx.vin, _inputTxs);

        // check that weather the NFT is transferred to the expected buyer or not and send funds
        uint fee = _checkNFTTransferAndSendFunds(_txId, _seller, _bidIdx, _transferTx.vout, _outputNFTIdx, nftIdx);
 
        emit NFTSold(
            _txId, 
            _seller, 
            _bidIdx, 
            transferTxId, 
            _outputNFTIdx, 
            nftIdx, 
            fee
        );

        return true;
    }

    /// @notice Checks the validity of schnorr signature
    /// @param _pubKeyX public key x-coordinate
    /// @param _msg msg hash that user signed
    /// @param _e schnorr signature challenge
    /// @param _s schnorr signature
    /// @param _v public key y-coordinate parity (27 or 28)
    function _verifySchnorr(
        bytes32 _pubKeyX,
        bytes32 _msg,
        bytes32 _e,
        bytes32 _s,
        uint8 _v
    ) internal pure returns (bool) {
        bytes32 sp = bytes32(Q - mulmod(uint256(_s), uint256(_pubKeyX), Q));
        bytes32 ep = bytes32(Q - mulmod(uint256(_e), uint256(_pubKeyX), Q));
        require(sp != 0, "BitcoinNFTMarketplace: wrong sig");
        address R = ecrecover(sp, _v, _pubKeyX, ep);
        require(R != address(0), "BitcoinNFTMarketplace: ecrecover failed");
        return _e == keccak256(
            abi.encodePacked(R, uint8(_v), _pubKeyX, _msg)
        );
    }

    /// @notice Checks that the bitcoin script provided by buyer is valid (so seller can send the btc to it)
    /// @param _script seller locking script (without op codes)
    /// @param _scriptType type of locking script (e.g. P2PKH, P2TR)
    function _checkScriptType(bytes memory _script, ScriptTypes _scriptType) private pure {
        if (_scriptType == ScriptTypes.P2PK || _scriptType == ScriptTypes.P2WSH || _scriptType == ScriptTypes.P2TR) {
            require(_script.length == 32, "BitcoinNFTMarketplace: invalid script");
        } else {
            require(_script.length == 20, "BitcoinNFTMarketplace: invalid script");
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
                "BitcoinNFTMarketplace: outpoint != input tx"
            );

            // sum of all inputs of transfer tx before the input that spent NFT
            _idx += BitcoinHelper.parseOutputValue(_inputTxs[i].vout, _outpointIndex);
        }

        (_outpointId, _outpointIndex) = BitcoinHelper.extractOutpoint(
            _vin,
            _inputTxs.length // this is the input that spent the NFT
        );

        // Checks that "outpoint tx id == _txId"
        require(
            (_outpointId == _txId) && (_outpointIndex == nfts[_txId][_seller].outputIdx),
            "BitcoinNFTMarketplace: outpoint not match with _txId"
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
    function _checkNFTTransferAndSendFunds(
        bytes32 _txId,
        address _seller,
        uint _bidIdx,
        bytes memory _vout,
        uint _outputNFTIdx,
        uint _nftIdxInput
    ) internal returns (uint _fee) {
        // find number of satoshis before the output that includes the NFT
        uint outputValue;
        for (uint i = 0; i < _outputNFTIdx; i++) {
            outputValue += BitcoinHelper.parseOutputValue(_vout, i);
        }

        if (_outputNFTIdx != 0) {
            require(
                _nftIdxInput > outputValue,
                "BitcoinNFTMarketplace: not transffered"
            );
        }

        require(
            _nftIdxInput <= outputValue + BitcoinHelper.parseValueFromSpecificOutputHavingScript(
                _vout,
                _outputNFTIdx,
                bids[_txId][_seller][_bidIdx].buyerBTCScript,
                bids[_txId][_seller][_bidIdx].buyerScriptType
            ),
            "BitcoinNFTMarketplace: not transffered"
        );

        nfts[_txId][_seller].isSold = true;

        // send ETH to seller and fee to treasury
        _fee = protocolFee * bids[_txId][_seller][_bidIdx].bidAmount / MAX_PROTOCOL_FEE;
        Address.sendValue(payable(_seller), bids[_txId][_seller][_bidIdx].bidAmount - _fee);
        if (_fee > 0) {
            Address.sendValue(payable(treasury), _fee);
        }
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
        require(msg.value >= feeAmount, "BitcoinNFTMarketplace: relay fee is not sufficient");

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

    /// @notice Returns a sliced bytes
    /// @param _data Data that is sliced
    /// @param _start Start index of slicing
    /// @param _end End index of slicing
    /// @return _result The result of slicing
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

    /// @notice Calculates bitcoin double hash function
    function _doubleHash(bytes memory _input) internal pure returns(bytes memory) {
        bytes32 inputHash1 = sha256(_input);
        bytes20 inputHash2 = ripemd160(abi.encodePacked(inputHash1));
        return abi.encodePacked(inputHash2);
    }

    /// @notice Compare two bytes string
    function _compareBytes(bytes memory _a, bytes memory _b) internal pure returns (bool) {
        return keccak256(_a) == keccak256(_b);
    }

    /// @notice Convert bytes with length 20 to address
    function _bytesToAddress(bytes memory _data) public pure returns (address) {
        require(_data.length == 20, "BitcoinNFTMarketplace: Invalid len");
        address addr;
        assembly {
            addr := mload(add(_data, 20))
        }
        return addr;
    }

    /// @notice Convert bytes with length 32 to bytes32
    function _convertToBytes32(bytes memory _data) public pure returns (bytes32) {
        require(_data.length == 32, "BitcoinNFTMarketplace: Invalid len");
        bytes32 result;
        assembly {
            result := mload(add(_data, 32))
        }
        return result;
    }
}