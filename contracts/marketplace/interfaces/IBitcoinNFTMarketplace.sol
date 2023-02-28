// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.8.4;

import "../../types/ScriptTypesEnum.sol";

interface IBitcoinNFTMarketplace {

	// Structures

    /// @notice Structure for passing Bitcoin tx to functions
    /// @param version Versions of tx
    /// @param vin Inputs of tx
    /// @param vout Outputs of tx
    /// @param locktime Locktimes of tx
	struct Tx {
        bytes4 version;
		bytes vin;
		bytes vout;
		bytes4 locktime;
  	}

    /// @notice Structure for storing NFT data
    /// @param outputIdx Index of output that includes NFT
    /// @param satoshiIdx Index of the inscribed satoshi in the output satoshis
    /// @param isSold True if the NFT is sold
    /// @param hasAccepted True if the seller accepted one of the bids
    /// @param bids List of all bids for the NFT
	struct NFT {
        uint outputIdx;
        uint satoshiIdx;
        bool isSold;
        bool hasAccepted;
  	}

    /// @notice Structure for recording buyers bids
    /// @param buyerBTCScript Seller will send the NFT to the provided script
    /// @param buyerETHAddress Buyer can withdraw ETH to this address
    /// @param bidAmount Amount of buyre's bid
    /// @param deadline Buyer cannot withdraw funds before deadline (it is based on the bitcoin block number)    		
    /// @param isAccepted True if the bid is accepted by seller
	struct Bid {
		bytes buyerBTCScript;
        ScriptTypes buyerScriptType;
		address buyerETHAddress;
		uint bidAmount;
        uint deadline;
        bool isAccepted;
  	}

  	// Events

    event NFTListed(bytes32 txId, uint outputIdx, uint satoshiIdx, address seller);

	// Read-only functions

    function transferDeadline() external view returns (uint);
	
	function relay() external view returns (address);

	// State-changing functions

    function setRelay(address _relay) external;
    
    function setTransferDeadline(uint _transferDeadline) external;

	function listNFT(
        bytes memory _bitcoinPubKey,
        ScriptTypes _scriptType,
        bytes32 _r,
        bytes32 _s,
        uint8 _v,
        Tx memory _tx,
        uint _outputIdx,
		uint _satoshiIdx
	) external returns (bool);

    function putBid(
        bytes32 _txId,
        address _seller, 
        bytes memory _buyerBTCScript,
        ScriptTypes _scriptType
    ) external payable returns (bool);

    function revokeBid(
        bytes32 _txId, 
        address _seller,
        uint _bidIdx
    ) external returns (bool);

    function acceptBid(bytes32 _txId, uint _bidIdx) external returns (bool);

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
    ) external returns (bool);

}