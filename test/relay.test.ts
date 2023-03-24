/* global artifacts contract describe before it assert web3 */
const BN = require('bn.js');
const utils = require('./utils.js');
const TXCHECK = require('./test_fixtures/blockWithTx.json');
const FORKEDCHAIN = require('./test_fixtures/forkedChain.json');
const REGULAR_CHAIN = require('./test_fixtures/headers.json');
const RETARGET_CHAIN = require('./test_fixtures/headersWithRetarget.json');
const REORG_AND_RETARGET_CHAIN = require('./test_fixtures/headersReorgAndRetarget.json');

import { assert, expect, use } from "chai";
const {BitcoinRESTAPI} = require('bitcoin_rest_api');
const {baseURLMainnet} = require('bitcoin_rest_api');
const {baseURLTestnet} = require('bitcoin_rest_api');
const {networkMainnet} = require('bitcoin_rest_api');
const {networkTestnet} = require('bitcoin_rest_api');
const fs = require('fs');
var path = require('path');
var jsonPath = path.join(__dirname, './test_fixtures', 'testMerkleRoots.json');
require('dotenv').config({path:"../../.env"});

import { deployments, ethers } from "hardhat";
import { Signer, BigNumber } from "ethers";
import { Relay } from "../src/types/Relay";
import { Relay__factory } from "../src/types/factories/Relay__factory";
import { deployMockContract, MockContract } from "@ethereum-waffle/mock-contract";
import { takeSnapshot, revertProvider } from "./block_utils";
import { time } from "@nomicfoundation/hardhat-network-helpers";

function revertBytes32(input: any) {
    let output = input.match(/[a-fA-F0-9]{2}/g).reverse().join('')
    return output;
};

function getTargetFromDiff(input: any) {
    const two = new BN(2);
    const a = new BN(208);
    const b = new BN(16);
    const c = new BN(1);
    const D = two.pow(a).mul(two.pow(b).sub(c));
    let target = D.div(new BN(input));
    return target;
};

describe("Relay", async () => {

    let relayFactory: Relay__factory;

    let relay1: Relay;
    let relay2: Relay;
    let relay3: Relay;

    let deployer: Signer;
    let signer1: Signer;
    let signer2: Signer;
    let signer3: Signer;

    let ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
    let ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
    let bitcoinRESTAPI: any;
    let merkleRoots: any;
    let disputeTime = 9*60;
    let proofTime = 6*60;
    let minCollateralDisputer = '100000000000000000'; // = 0.1 * 10 ^ 18
    let minCollateralRelayer = BigNumber.from(1000000000000000); // = 0.001 * 10 ^ 18
    let relayerCollateral = '0.001';
    let disputeRewardPercentage = 100;

    let mockTDT: MockContract;

    const _genesisHeight: any = 99 * 2016 + 31 * 63;

    before(async () => {

        [deployer, signer1, signer2, signer3] = await ethers.getSigners();

        relayFactory = new Relay__factory(
            deployer
        );

        bitcoinRESTAPI = new BitcoinRESTAPI(networkMainnet, baseURLMainnet, 2);

        // read block headers from file
        let data = fs.readFileSync(jsonPath, 'utf-8');
        merkleRoots = data.split('\n');

        relay1 = await deployRelay();

        const TDTcontract = await deployments.getArtifact(
            "contracts/erc20/interfaces/ITeleBTC.sol:ITeleBTC"
        );
        mockTDT = await deployMockContract(
            deployer,
            TDTcontract.abi
        )

    });

    async function setTDTbalanceOf(balance: any): Promise<void> {
        await mockTDT.mock.balanceOf.returns(balance);
    }

    async function setTDTtransfer(transfersTDT: boolean): Promise<void> {
        await mockTDT.mock.transfer.returns(transfersTDT);
    }

    const deployRelay = async (
        _signer?: Signer
    ): Promise<Relay> => {
        const relayFactory = new Relay__factory(
            _signer || deployer
        );

        let _height = _genesisHeight;
        let _heightBigNumber = BigNumber.from(_genesisHeight)
        // todo: below should be Merkle root but for now since it is already some hash we don't care
        let _genesisMerkleRoot = '0x' + await bitcoinRESTAPI.getHexBlockHash(_height - (_height % 2016));
        // todo: below should be Merkle root but for now since it is already some hash we don't care
        let _periodStart = await bitcoinRESTAPI.getHexBlockHash(_height - (_height % 2016)); 
        _periodStart = '0x' + revertBytes32(_periodStart);
        let _startTimestamp = 100000000; // todo: correct it
        
        const relay1 = await relayFactory.deploy(
            _genesisMerkleRoot,
            _heightBigNumber,
            _periodStart,
            _startTimestamp,
            0, // TODO: pass target
            ZERO_ADDRESS
        );

        relay1.setDisputeRewardPercentage(disputeRewardPercentage);

        return relay1;
    };

    const deployRelayWithGenesis = async (
        _genesisMerkleRoot: any,
        _genesisHeight: any,
        _periodStart: any,
        _startTimestamp: any,
        _target: any,
        _signer?: Signer
    ): Promise<Relay> => {
        const relayFactory = new Relay__factory(
            _signer || deployer
        );

        let _heightBigNumber = BigNumber.from(_genesisHeight)
        _periodStart = '0x' + revertBytes32(_periodStart);

        const relayTest = await relayFactory.deploy(
            _genesisMerkleRoot,
            _heightBigNumber,
            _periodStart,
            _startTimestamp,
            _target,
            ZERO_ADDRESS
        );

        return relayTest;
    };

    // ------------------------------------
    // SCENARIOS:
    // describe('Submitting block headers', async () => {

    //     it('check the owner', async function () {
    //         let theOwnerAddress = await relay1.owner()

    //         let theDeployerAddress = await deployer.getAddress();

    //         expect(theOwnerAddress).to.equal(theDeployerAddress);
    //     })

    //     it('submit old block headers', async function () {
    //         this.timeout(0);
    //         let startFrom = 31; // upon change, please also change _genesisHeight
    //         // submit block headers up to 100*2016
    //         for (let i = startFrom; i < 32; i++) {

    //             let merkleRootsNew = '0x';

    //             let blockHeaderOld = '';

    //             if (i == startFrom) {
    //                 blockHeaderOld = '0x' + merkleRoots[startFrom * 63];
    //                 for (let j = 1; j < 63; j++) {
    //                     blockHeadersNew = blockHeadersNew + merkleRoots[j + i*63];
    //                 }
    //             } else {
    //                 blockHeaderOld = '0x' + merkleRoots[i*63 - 1];
    //                 for (let j = 0; j < 63; j++) {
    //                     blockHeadersNew = blockHeadersNew + merkleRoots[j + i*63];
    //                 }
    //             }

    //             expect(
    //                 await relay1.addHeaders(
    //                     blockHeaderOld, // anchor header
    //                     blockHeadersNew // new header;
    //                 )
    //             ).to.emit(relay1, "BlockAdded")

    //         }

    //     });

    //     it('revert a block header with wrong PoW', async function () {
    //         let blockHeaderOld = merkleRoots[2013];
    //         blockHeaderOld = '0x' + blockHeaderOld;
    //         // below = blockheader[2014] with a different nonce
    //         let blockHeaderNew = '0x' + '02000000b9985b54b29f5244d2884e497a68523a6f8a3874dadc1db26804000000000000f3689bc987a63f3d9db84913a4521691b6292d46be11166412a1bb561159098f238e6b508bdb051a6ffb0278';
            
    //         await expect(
    //             relay1.addHeaders(
    //                 blockHeaderOld, // anchor header
    //                 blockHeaderNew // new header;
    //             )
    //         ).revertedWith('Relay: insufficient work')

    //     });

    //     it('revert a block header with wrong previous hash', async function () {
    //         let blockHeaderOld = merkleRoots[2013];
    //         blockHeaderOld = '0x' + blockHeaderOld;
    //         // below = blockheader[2014] with a different previous hash (equal to its own hash)
    //         let blockHeaderNew = '0x' + '0200000090750e6782a6a91bf18823869519802e76ee462f462e8fb2cc00000000000000f3689bc987a63f3d9db84913a4521691b6292d46be11166412a1bb561159098f238e6b508bdb051a6ffb0277';
            
    //         await expect(
    //             relay1.addHeaders(
    //                 blockHeaderOld, // anchor header
    //                 blockHeaderNew // new header;
    //             )
    //         ).revertedWith('Relay: no link')

    //     });

    //     it('submit a block header for a new epoch with same target (addHeaders)', async () => {
    //         let blockHeaderOld = '0x' + merkleRoots[2015];
    //         // block header new has the same target as block header old
    //         let blockHeaderNew = "0x010000009d6f4e09d579c93015a83e9081fee83a5c8b1ba3c86516b61f0400000000000025399317bb5c7c4daefe8fe2c4dfac0cea7e4e85913cd667030377240cadfe93a4906b508bdb051a84297df7"

    //         await expect(
    //             relay1.addHeaders(
    //                 blockHeaderOld, // anchor header
    //                 blockHeaderNew // new header;
    //             )
    //         ).revertedWith('Relay: headers should be submitted by calling addHeadersWithRetarget')
    //     });

    //     it('submit a block header with new target (addHeaders => unsuccessful)', async () => {
    //         let blockHeaderOld = merkleRoots[2015];
    //         let blockHeaderNew = await bitcoinRESTAPI.getHexBlockHeader(100*2016);
    //         blockHeaderOld = '0x' + blockHeaderOld;
    //         blockHeaderNew = '0x' + blockHeaderNew;

    //         await expect(
    //             relay1.addHeaders(
    //                 blockHeaderOld, // anchor header
    //                 blockHeaderNew // new header;
    //             )
    //         ).revertedWith('Relay: unexpected retarget')

    //     });

    //     it('submit a block header with new target', async () => {
    //         let newHeight = BigNumber.from(100*2016);
    //         let blockHeaderNew = await bitcoinRESTAPI.getHexBlockHeader(newHeight); // this is the new block header
        
    //         blockHeaderNew = '0x' + blockHeaderNew;
    //         let oldPeriodStartHeader = '0x' + merkleRoots[0];
    //         let oldPeriodEndHeader = '0x' + merkleRoots[2015];

    //         // First block of the new epoch gets submitted successfully
    //         expect(
    //             await relay1.addHeadersWithRetarget(
    //                 oldPeriodStartHeader,
    //                 oldPeriodEndHeader,
    //                 blockHeaderNew
    //             )
    //         ).to.emit(relay1, "BlockAdded")

    //         let blockHeaderNext = await bitcoinRESTAPI.getHexBlockHeader(newHeight.add(1))
    //         let currentHash = '0x' + blockHeaderNext.slice(8, 72);
    
    //         // Hash of the block is stored
    //         expect(
    //             await relay1.getBlockHeaderHash(newHeight, 0)
    //         ).to.equal(currentHash)
    //         // Height of the block is stored
    //         expect(
    //             await relay1.findHeight(currentHash)
    //         ).to.equal(newHeight)
    //     });

    // });

    // describe('Submitting block headers with forks', async () => {
    //     /* eslint-disable-next-line camelcase */
    //     const { bitcoinPeriodStart, bitcoinCash, bitcoin } = FORKEDCHAIN;
    //     // bitcoin[4] is the first forked block
        
    //     let relayTest: any;

    //     beforeEach(async () => {

    //         relayTest = await deployRelayWithGenesis(
    //             bitcoinCash[0].blockHeader,
    //             bitcoinCash[0].blockNumber,
    //             bitcoinPeriodStart.blockHash
    //         );

    //     });
        
    //     it('successfully create a fork', async function () {
    //         // submit the main fork
    //         for (let i = 1; i < 7; i++) {
    //             await relayTest.addHeaders(
    //                 '0x' + bitcoinCash[i - 1].blockHeader,
    //                 '0x' + bitcoinCash[i].blockHeader
    //             )
    //         }
    //         // submit the second fork
    //         // note: confirmation number = 3
    //         for (let i = 4; i < 7; i++) {
    //             expect(
    //                 await relayTest.addHeaders(
    //                     '0x' + bitcoin[i - 1].blockHeader,
    //                     '0x' + bitcoin[i].blockHeader
    //                 )
    //             ).to.emit(relayTest, "BlockAdded")
    //         }
    //     });

    //     it('not be able to submit too old block headers to form a fork', async function () {
    //         // submit the main fork
    //         for (let i = 1; i < 8; i++) {
    //             await relayTest.addHeaders(
    //                 '0x' + bitcoinCash[i - 1].blockHeader,
    //                 '0x' + bitcoinCash[i].blockHeader
    //             )
    //         }
    //         // submit the second fork
    //         // note: confirmation number = 3
    //         await expect(
    //             relayTest.addHeaders(
    //                 '0x' + bitcoin[3].blockHeader,
    //                 '0x' + bitcoin[4].blockHeader
    //             )
    //         ).revertedWith("Relay: block headers are too old")
    //     });

    //     it('successfully prune the chain', async function () {
    //         // submit the main fork
    //         for (let i = 1; i < 7; i++) {
    //             await relayTest.addHeaders(
    //                 '0x' + bitcoinCash[i - 1].blockHeader,
    //                 '0x' + bitcoinCash[i].blockHeader
    //             )
    //         }
    //         // submit the second fork
    //         // note: confirmation number = 3
    //         for (let i = 4; i < 7; i++) {
    //             await relayTest.addHeaders(
    //                 '0x' + bitcoin[i - 1].blockHeader,
    //                 '0x' + bitcoin[i].blockHeader
    //             )
    //         }
    //         // check that the fork exists on the relay1
    //         for (let i = 4; i < 7; i++) {
    //             expect(
    //                 await relayTest.getNumberOfSubmittedHeaders(
    //                     bitcoin[i].blockNumber
    //                 )
    //             ).equal(2);
    //         }

    //         // this block finalizes a block in the forked chain so the main chain should be pruned
    //         expect(
    //             await relayTest.addHeaders(
    //                 '0x' + bitcoin[6].blockHeader,
    //                 '0x' + bitcoin[7].blockHeader
    //             )
    //         ).to.emit(relayTest, "BlockFinalized")

    //         // no other block header has remained in the same height as the finalized block
    //         expect(await relayTest.getNumberOfSubmittedHeaders(bitcoin[4].blockNumber)).equal(1);
    //         // and that one block header belongs to the finalized chain (bitcoin)
    //         expect(await relayTest.getBlockHeaderHash(bitcoin[4].blockNumber, 0)).equal('0x' + revertBytes32(bitcoin[4].blockHash));
    //     });

    //     it('successfully emit FinalizedBlock', async function () {
    //         // submit the main fork
    //         for (let i = 1; i < 3; i++) {
    //             await relayTest.addHeaders(
    //                 '0x' + bitcoinCash[i - 1].blockHeader,
    //                 '0x' + bitcoinCash[i].blockHeader
    //             )
    //         }
    //         // blocks start getting finalized
    //         // note: confirmation number = 3
    //         for (let i = 3; i < 7; i++) {
    //             expect(
    //                 await relayTest.addHeaders(
    //                     '0x' + bitcoinCash[i - 1].blockHeader,
    //                     '0x' + bitcoinCash[i].blockHeader
    //                 )
    //             ).to.emit(relayTest, "BlockFinalized")
    //         }
    //         // submit the second fork
    //         // no new height is being added, so no block is getting finalized
    //         for (let i = 4; i < 7; i++) {
    //             await expect(
    //                 relayTest.addHeaders(
    //                     '0x' + bitcoin[i - 1].blockHeader,
    //                     '0x' + bitcoin[i].blockHeader
    //                 )
    //             ).to.not.emit(relayTest, "BlockFinalized")
    //         }
    //         // a new height gets added, so new block gets finalized
    //         expect(
    //             await relayTest.addHeaders(
    //                 '0x' + bitcoin[6].blockHeader,
    //                 '0x' + bitcoin[7].blockHeader
    //             )
    //         ).to.emit(relayTest, "BlockFinalized")
    //     });

        // it('appends multiple blocks in one height', async () => {
        //     let newTimestamp;
        //     // initialize mock contract
        //     await setTDTbalanceOf(0);
        //     await setTDTtransfer(true);
        //     // add 1 block
        //     relay2.addBlock(
        //         genesis.merkle_root,
        //         chain[0].merkle_root,
        //         {value: ethers.utils.parseEther(relayerCollateral)}
        //     )
        //     for (let i = 0; i < 7; i++) {
        //         newTimestamp = await time.latest() + disputeTime;
        //         await time.setNextBlockTimestamp(newTimestamp);
        //         // add another block on top
        //         relay2.addBlock(
        //             chain[i].merkle_root,
        //             chain[i+1].merkle_root,
        //             {value: ethers.utils.parseEther(relayerCollateral)}
        //         )
        //     }
        //     newTimestamp = await time.latest() + disputeTime;
        //     await time.setNextBlockTimestamp(newTimestamp);
        //     // add another block in the same height
        //     relay2.addBlock(
        //         chain[7].merkle_root,
        //         orphan_562630.merkle_root,
        //         {value: ethers.utils.parseEther(relayerCollateral)}
        //     )
        //     // todo: check proof for both blocks in height 8
        // });
    // });

    // describe('Unfinalizing a finalized block header', async () => {
    //     // default fanalization parameter is 3
    //     // oldChain = [478558, 478559, 478560, 478561, 478562, 478563]
    //     // newChain = [478558, 478559", 478560", 478561", 478562", 478563"]
    //     const periodStart = FORKEDCHAIN.bitcoinPeriodStart;
    //     const oldChain = FORKEDCHAIN.bitcoinCash;
    //     const newChain = FORKEDCHAIN.bitcoin;

    //     let relayTest: any;
    //     let snapshotId: any;

    //     beforeEach(async () => {
    //         snapshotId = await takeSnapshot(signer1.provider);

    //         // deploy bitcoin relay1 contract with block 478558 (index 0 is 478555)
    //         relayTest = await deployRelayWithGenesis(
    //             oldChain[3].blockHeader,
    //             oldChain[3].blockNumber,
    //             periodStart.blockHash
    //         );

    //         // finalize blocks 478558 and 478559
    //         await expect(
    //             relayTest.addHeaders(
    //                 "0x" + oldChain[3].blockHeader,
    //                 "0x" + oldChain[4].blockHeader + oldChain[5].blockHeader + 
    //                     oldChain[6].blockHeader + oldChain[7].blockHeader
    //             )
    //         ).to.emit(relayTest, "BlockFinalized").withArgs(
    //             478559,
    //             '0x' + revertBytes32(oldChain[4].blockHash),
    //             '0x' + revertBytes32(oldChain[3].blockHash),
    //             await deployer.getAddress(),
    //             0,
    //             0
    //         );

    //     });
        
    //     afterEach(async () => {
    //         await revertProvider(signer1.provider, snapshotId);
    //     });
        
    //     it('unfinalize block 478559 and finalize block 478559"', async function () {
    //         // pause relay1
    //         await relayTest.pauseRelay();
            
    //         // increase finalization parameter from 3 to 4
    //         await relayTest.setFinalizationParameter(4);

    //         // submit new blocks [478559", 478560", 478561", 478562", 478563"] and finalize 478559"
    //         await expect(
    //             relayTest.ownerAddHeaders(
    //                 "0x" + oldChain[3].blockHeader,
    //                 "0x" + newChain[4].blockHeader + newChain[5].blockHeader + 
    //                     newChain[6].blockHeader + newChain[7].blockHeader + newChain[8].blockHeader,
    //             )
    //         ).to.emit(relayTest, "BlockFinalized").withArgs(
    //             478559,
    //             '0x' + revertBytes32(newChain[4].blockHash),
    //             '0x' + revertBytes32(newChain[3].blockHash),
    //             await deployer.getAddress(),
    //             0,
    //             0
    //         );
            
    //         // check that 478559 is removed and 478559" is added
    //         expect(
    //             relayTest.findHeight('0x' + revertBytes32(oldChain[4].blockHash))
    //         ).to.be.reverted;

    //         expect(
    //             await relayTest.findHeight('0x' + revertBytes32(newChain[4].blockHash))
    //         ).to.be.equal(478559);

    //     });

    // });

    // describe('Check tx inclusion', async () => {
    //     /* eslint-disable-next-line camelcase */
    //     const { block, transaction } = TXCHECK;

    //     it('errors if the smart contract is paused', async () => {

    //         let relayDeployer = await relay1.connect(deployer);
    //         let _height = block.height;
    //         // Get the fee amount needed for the query
    //         let fee = await relay1.getBlockHeaderFee(_height, 0);
    //         // pause the relay1
    //         await relayDeployer.pauseRelay();

    //         await expect(
    //             relayDeployer.checkTxProof(
    //                 transaction.tx_id,
    //                 block.height,
    //                 transaction.intermediate_nodes,
    //                 transaction.index,
    //                 {value: fee}
    //             )
    //         ).to.revertedWith("Pausable: paused")
            
    //         // unpause the relay1
    //         await relayDeployer.unpauseRelay();
    //     });

    //     it('transaction id should be non-zero',async() => {
    //         let relaySigner1 = await relay1.connect(signer1);
    //         let _height = block.height;
    //         // Get the fee amount needed for the query
    //         let fee = await relay1.getBlockHeaderFee(_height, 0);

    //         // See if the transaction check goes through successfully
    //         await expect(
    //             relaySigner1.checkTxProof(
    //                 "0x0000000000000000000000000000000000000000000000000000000000000000",
    //                 block.height,
    //                 transaction.intermediate_nodes,
    //                 transaction.index,
    //                 {value: fee}
    //             )
    //         ).revertedWith("Relay: txid should be non-zero")
    //     });

    //     it('errors if the requested block header is not on the relay1 (it is too old)', async () => {

    //         let relayDeployer = await relay1.connect(deployer);
    //         let _height = block.height;
    //         // Get the fee amount needed for the query
    //         let fee = await relay1.getBlockHeaderFee(_height, 0);

    //         await expect(
    //             relayDeployer.checkTxProof(
    //                 transaction.tx_id,
    //                 block.height - 100,
    //                 transaction.intermediate_nodes,
    //                 transaction.index,
    //                 {value: fee}
    //             )
    //         ).to.revertedWith("Relay: the requested height is not submitted on the relay1 (too old)")

    //     });

    //     it('check transaction inclusion -> when included',async() => {
    //         let relaySigner1 = await relay1.connect(signer1);
    //         // Get parameters before sending the query
    //         let relayETHBalance0 = await relay1.availableTNT();
    //         let currentEpochQueries0 = await relaySigner1.currentEpochQueries();
    //         let _height = block.height;
    //         // Get the fee amount needed for the query
    //         let fee = await relay1.getBlockHeaderFee(_height, 0);

    //         // See if the transaction check goes through successfully
    //         expect(
    //             await relaySigner1.callStatic.checkTxProof(
    //                 transaction.tx_id,
    //                 _height,
    //                 transaction.intermediate_nodes,
    //                 transaction.index,
    //                 {value: fee}
    //             )
    //         ).equal(true);
    //         // Actually change the state
    //         await relaySigner1.checkTxProof(
    //             transaction.tx_id,
    //             _height,
    //             transaction.intermediate_nodes,
    //             transaction.index,
    //             {value: fee}
    //         )
            
    //         let currentEpochQueries1 = await relaySigner1.currentEpochQueries();
    //         // Check if the number of queries is being counted correctly for fee calculation purposes
    //         expect(currentEpochQueries1.sub(currentEpochQueries0)).to.equal(1);

    //         let relayETHBalance1 = await relay1.availableTNT();
    //         // Expected fee should be equal to the contract balance after tx is processed
    //         expect(relayETHBalance1.sub(relayETHBalance0)).to.equal(fee);
    //     });

    //     it('reverts when enough fee is not paid',async() => {
    //         let relaySigner1 = await relay1.connect(signer1);
    //         // Get parameters before sending the query
    //         let relayETHBalance0 = await relay1.provider.getBalance(relay1.address);
    //         let currentEpochQueries0 = await relaySigner1.currentEpochQueries();
    //         let _height = block.height;
    //         // Get the fee amount needed for the query
    //         let fee = await relay1.getBlockHeaderFee(_height, 0);

    //         // See if the transaction check fails
    //         await expect(
    //             relaySigner1.checkTxProof(
    //                 transaction.tx_id,
    //                 _height,
    //                 transaction.intermediate_nodes,
    //                 transaction.index,
    //                 {value: fee.sub(1)}
    //             )
    //         ).revertedWith("Relay: low fee")
            
    //         let currentEpochQueries1 = await relaySigner1.currentEpochQueries();
    //         // Check if the number of queries is being counted correctly for fee calculation purposes
    //         expect(currentEpochQueries1.sub(currentEpochQueries0)).to.equal(0);

    //         let relayETHBalance1 = await relay1.provider.getBalance(relay1.address);
    //         // Contract balance doesn't change
    //         expect(relayETHBalance1).equal(relayETHBalance0);
    //     });

    //     it('check transaction inclusion -> when not included',async() => {
    //         let relaySigner1 = await relay1.connect(signer1);
    //         // Get parameters before sending the query
    //         let relayETHBalance0 = await relay1.provider.getBalance(relay1.address);
    //         let currentEpochQueries0 = await relaySigner1.currentEpochQueries();
    //         let _height = block.height;
    //         // Get the fee amount needed for the query 
    //         let fee = await relay1.getBlockHeaderFee(_height, 0);

    //         // See if the transaction check returns false
    //         expect(
    //             await relaySigner1.callStatic.checkTxProof(
    //                 transaction.tx_id,
    //                 _height - 1,
    //                 transaction.intermediate_nodes,
    //                 transaction.index,
    //                 {value: fee}
    //             )
    //         ).equal(false);
    //         // Actually change the state
    //         await relaySigner1.checkTxProof(
    //             transaction.tx_id,
    //             _height - 1,
    //             transaction.intermediate_nodes,
    //             transaction.index,
    //             {value: fee}
    //         )
            
    //         let currentEpochQueries1 = await relaySigner1.currentEpochQueries();
    //         // Check if the number of queries is being counted correctly for fee calculation purposes
    //         expect(currentEpochQueries1.sub(currentEpochQueries0)).to.equal(1);

    //         let relayETHBalance1 = await relay1.provider.getBalance(relay1.address);
    //         // Expected fee should be equal to the contract balance after tx is processed
    //         expect(relayETHBalance1.sub(relayETHBalance0)).to.equal(fee);
    //     });

    //     it("reverts when tx's block is not finalized",async() => {
    //         let relaySigner1 = await relay1.connect(signer1);
    //         // Get parameters before sending the query
    //         let relayETHBalance0 = await relay1.provider.getBalance(relay1.address);
    //         let currentEpochQueries0 = await relaySigner1.currentEpochQueries();
    //         let _height = block.height;
    //         // Get the fee amount needed for the query 
    //         let fee = await relay1.getBlockHeaderFee(_height, 0);

    //         // See if the transaction check returns false
    //         await expect(
    //             relaySigner1.checkTxProof(
    //                 transaction.tx_id,
    //                 _height + 1,
    //                 transaction.intermediate_nodes,
    //                 transaction.index,
    //                 {value: fee}
    //             )
    //         ).revertedWith("Relay: not finalized");
            
    //         let currentEpochQueries1 = await relaySigner1.currentEpochQueries();

    //         // Check if the number of queries is being counted correctly for fee calculation purposes
    //         expect(currentEpochQueries1.sub(currentEpochQueries0)).to.equal(0);

    //         let relayETHBalance1 = await relay1.provider.getBalance(relay1.address);

    //         // Expected fee should be equal to the contract balance after tx is processed
    //         expect(relayETHBalance1).equal(relayETHBalance0);
    //     });

    // });

    // ------------------------------------
    // FUNCTIONS:
    describe('#constructor', async () => {
        /* eslint-disable-next-line camelcase */
        const { genesis, orphan_562630 } = REGULAR_CHAIN;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.merkle_root,
                genesis.height,
                orphan_562630.merkle_root,
                genesis.timestamp,
                genesis.difficulty,
                ZERO_ADDRESS
            );
        });

        it('errors if the caller is being an idiot', async () => {

            await expect(
                relayFactory.deploy(
                    ZERO_HASH,
                    genesis.height,
                    genesis.merkle_root,
                    genesis.timestamp,
                    genesis.difficulty,
                    ZERO_ADDRESS
                )
            ).to.revertedWith("Relay: genesis root is zero")
        });

        it('stores genesis block info', async () => {

            expect(
                await relay2.relayGenesisMerkleRoot()
            ).to.equal(genesis.merkle_root)

            // expect(
            //     await relay2.findAncestor(
            //         genesis.merkle_root,
            //         0
            //     )
            // ).to.equal(genesis.merkle_root)

            expect(
                await relay2.findHeight(genesis.merkle_root)
            ).to.equal(genesis.height)
        });
    });

    describe('#pauseRelay', async () => {
        /* eslint-disable-next-line camelcase */
        const { genesis, orphan_562630 } = REGULAR_CHAIN;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.merkle_root,
                genesis.height,
                orphan_562630.merkle_root,
                genesis.timestamp,
                genesis.difficulty,
                ZERO_ADDRESS
            );
        });

        it('errors if the caller is not owner', async () => {

            let relaySigner1 = await relay2.connect(signer1);
            await expect(
                relaySigner1.pauseRelay()
            ).to.revertedWith("Ownable: caller is not the owner")
        });
    });

    describe('#unpauseRelay', async () => {
        /* eslint-disable-next-line camelcase */
        const { genesis, orphan_562630 } = REGULAR_CHAIN;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.merkle_root,
                genesis.height,
                orphan_562630.merkle_root,
                genesis.timestamp,
                genesis.difficulty,
                ZERO_ADDRESS
            );
        });

        it('errors if the caller is not owner', async () => {

            let relaySigner1 = await relay2.connect(signer1);
            let relayDeployer = await relay2.connect(deployer);
            // owner pauses the relay
            await relayDeployer.pauseRelay();

            await expect(
                relaySigner1.unpauseRelay()
            ).to.revertedWith("Ownable: caller is not the owner")
        });
    });

    describe('#getBlockMerkleRoot', async () => {
        /* eslint-disable-next-line camelcase */
        const { chain, genesis, orphan_562630 } = REGULAR_CHAIN;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.merkle_root,
                genesis.height,
                orphan_562630.merkle_root,
                genesis.timestamp,
                genesis.difficulty,
                ZERO_ADDRESS
            );
        });

        it('views the merkle root correctly', async () => {
            expect(
                await relay2.addBlock(genesis.merkle_root, chain[0].merkle_root)
            ).to.emit(relay2, "BlockAdded")
            expect(
                await relay2.getBlockMerkleRoot(chain[0].height, 0)
            ).to.equal(chain[0].merkle_root)
        });

    });

    describe('## Setters', async () => {
        /* eslint-disable-next-line camelcase */
        const { genesis, orphan_562630 } = REGULAR_CHAIN;
        let relaySigner2: any;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.merkle_root,
                genesis.height,
                orphan_562630.merkle_root,
                genesis.timestamp,
                genesis.difficulty,
                ZERO_ADDRESS
            );
            relaySigner2 = await relay2.connect(signer2);
        });

        it('#setRewardAmountInTDT', async () => {
            await expect(
                await relay2.setRewardAmountInTDT(5)
            ).to.emit(
                relay2, "NewRewardAmountInTDT"
            ).withArgs(0, 5);

            expect(
                await relay2.rewardAmountInTDT()
            ).to.equal(5)
        });

        it('setRewardAmountInTDT owner check', async () => {
            await expect(
                relaySigner2.setRewardAmountInTDT(5)
            ).to.revertedWith("Ownable: caller is not the owner")
        });

        it('#setFinalizationParameter', async () => {
            await expect(
                await relay2.setFinalizationParameter(6)
            ).to.emit(
                relay2, "NewFinalizationParameter"
            ).withArgs(5, 6);

            expect(
                await relay2.finalizationParameter()
            ).to.equal(6)
        });

        it('setFinalizationParameter owner check', async () => {
            await expect(
                relaySigner2.setFinalizationParameter(6)
            ).to.revertedWith("Ownable: caller is not the owner")
        });

        it('#setRelayerPercentageFee', async () => {
            await expect(
                await relay2.setRelayerPercentageFee(10)
            ).to.emit(
                relay2, "NewRelayerPercentageFee"
            ).withArgs(500, 10);

            expect(
                await relay2.relayerPercentageFee()
            ).to.equal(10)
        });

        it('setRelayerPercentageFee owner check', async () => {
            await expect(
                relaySigner2.setRelayerPercentageFee(5)
            ).to.revertedWith("Ownable: caller is not the owner")
        });

        it('#setEpochLength', async () => {
            await expect(
                await relay2.setEpochLength(10)
            ).to.emit(
                relay2, "NewEpochLength"
            ).withArgs(2016, 10);

            expect(
                await relay2.epochLength()
            ).to.equal(10)
        });

        it('setEpochLength owner check', async () => {
            await expect(
                relaySigner2.setEpochLength(10)
            ).to.revertedWith("Ownable: caller is not the owner")
        });

        it('#setBaseQueries', async () => {
            await expect(
                await relay2.setBaseQueries(100)
            ).to.emit(
                relay2, "NewBaseQueries"
            ).withArgs(2016, 100);

            expect(
                await relay2.baseQueries()
            ).to.equal(100)
        });

        it('setBaseQueries owner check', async () => {
            await expect(
                relaySigner2.setBaseQueries(100)
            ).to.revertedWith("Ownable: caller is not the owner")
        });

        it('#setSubmissionGasUsed', async () => {
            await expect(
                await relay2.setSubmissionGasUsed(100)
            ).to.emit(
                relay2, "NewSubmissionGasUsed"
            ).withArgs(300000, 100);
            
            expect(
                await relay2.submissionGasUsed()
            ).to.equal(100)
        });

        it('setSubmissionGasUsed owner check', async () => {
            await expect(
                relaySigner2.setSubmissionGasUsed(100)
            ).to.revertedWith("Ownable: caller is not the owner")
        });

        // todo: no tests for setTeleportDAOToken, setDisputeTime, setProofTime, setMinCollateralRelayer,
        // setMinCollateralDisputer, setDisputeRewardPercentage, setProofRewardPercentage yet
    });

    describe('#addBlock', async () => {
        /* eslint-disable-next-line camelcase */
        const { chain, genesis, orphan_562630 } = REGULAR_CHAIN;

        beforeEach(async () => {

            relay2 = await relayFactory.deploy(
                genesis.merkle_root,
                genesis.height,
                orphan_562630.merkle_root,
                genesis.timestamp,
                genesis.difficulty,
                mockTDT.address
            );
            await relay2.setMinCollateralRelayer(minCollateralRelayer);
            await expect(
                relay2.setDisputeTime(BigNumber.from(disputeTime))
            ).to.emit(relay2, "NewDisputeTime");
            await expect(
                relay2.setProofTime(BigNumber.from(proofTime))
            ).to.emit(relay2, "NewProofTime");
        });

        it('errors if the smart contract is paused', async () => {
            // pause the relay
            await relay2.pauseRelay();

            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.revertedWith("Pausable: paused")
        });

        it("errors if relayer doesn't have enough collateral", async () => {

            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root
                )
            ).to.revertedWith("Relay: low collateral")
        });

        it('errors if the anchor is unknown', async () => {
            await expect(
                relay2.addBlock(
                    chain[0].merkle_root,
                    chain[1].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.revertedWith("Relay: unknown block")
        });

        it('errors if the length of the merkle root is not correct', async () => {
            await expect(
                relay2.addBlock(
                    genesis.merkle_root + '0',
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.reverted
            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root + '0',
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.reverted
        });

        it('appends new links to the chain and fires an event', async () => {
            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")
        });

        it('appends new links to the chain and previous block gets verified', async () => {
            let relay2Deployer = await relay2.connect(deployer);
            let relay2Signer1 = await relay2.connect(signer1);
            // add 1 block
            await expect(
                relay2Deployer.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")

            let balanceBefore = await deployer.getBalance();
            let newTimestamp = await time.latest() + disputeTime;
            await time.setNextBlockTimestamp(newTimestamp);
            // add another block on top
            await expect(
                relay2Signer1.addBlock(
                    chain[0].merkle_root,
                    chain[1].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded").to.emit(relay2, "BlockVerified")

            // relayer of the first block gets back its collateral
            let balanceAfter = await deployer.getBalance();
            expect((balanceAfter.sub(balanceBefore)).toString() == relayerCollateral);
        });

        it('appends new links to the chain and a block gets finalized', async () => {
            let newTimestamp;
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            // add 1 block
            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")
            for (let i = 0; i < 4; i++) {
                newTimestamp = await time.latest() + disputeTime;
                await time.setNextBlockTimestamp(newTimestamp);
                // add another block on top
                await expect(
                    relay2.addBlock(
                        chain[i].merkle_root,
                        chain[i+1].merkle_root,
                        {value: ethers.utils.parseEther(relayerCollateral)}
                    )
                ).to.emit(relay2, "BlockAdded").to.emit(relay2, "BlockVerified")
            }
            newTimestamp = await time.latest() + disputeTime;
            await time.setNextBlockTimestamp(newTimestamp);
            // add another block on top
            await expect(
                relay2.addBlock(
                    chain[4].merkle_root,
                    chain[5].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded").to.emit(relay2, "BlockFinalized")
        });

        it('cannot append a new link when prev dispute time has not passed', async () => {
            // add 1 block
            await relay2.addBlock(
                genesis.merkle_root,
                chain[0].merkle_root,
                {value: ethers.utils.parseEther(relayerCollateral)}
            )

            let newTimestamp = await time.latest() + disputeTime - 1;
            await time.setNextBlockTimestamp(newTimestamp);
            // add another block on top
            await expect(
                relay2.addBlock(
                    chain[0].merkle_root,
                    chain[1].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.revertedWith("Relay: not verified")
        });

        it('cannot append a replica', async () => {
            // add 1 block
            await relay2.addBlock(
                genesis.merkle_root,
                chain[0].merkle_root,
                {value: ethers.utils.parseEther(relayerCollateral)}
            )
            let newTimestamp = await time.latest() + disputeTime;
            await time.setNextBlockTimestamp(newTimestamp);
            // add another block on top
            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.revertedWith("Relay: already submitted")
        });

        it("contract has no TNT but doesn't revert when paying a relayer", async () => {
            let relay2Balance0 = await relay2.availableTNT();
            expect(relay2Balance0).to.equal(BigNumber.from(0));
            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")
            let relay2Balance1 = await relay2.availableTNT();
            expect(relay2Balance1).to.equal(BigNumber.from(0));
        });

        it("contract has no TNT but has some TDT so rewards relayer only in TDT", async () => {
            const rewardAmountInTDTtest = 100;
            await relay2.setRewardAmountInTDT(rewardAmountInTDTtest);
            // initialize mock contract
            await setTDTbalanceOf(2 * rewardAmountInTDTtest);
            expect (await relay2.availableTDT()).equal(2 * rewardAmountInTDTtest)
            await setTDTtransfer(true);
            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")
        });

        it("fails in sending reward in TDT but submission goes through successfully", async () => {
            const rewardAmountInTDTtest = 100;
            await relay2.setRewardAmountInTDT(rewardAmountInTDTtest);
            // initialize mock contract
            await setTDTbalanceOf(2 * rewardAmountInTDTtest);
            await setTDTtransfer(false);

            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[0].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")
        });

        it("contract has enough TNT so pays the relayer", async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            let relayer1 = await relay2.connect(signer1);
            let relayer2 = await relay2.connect(signer2);
            let user = await relay2.connect(signer3);

            let newTimestamp;

            // check relayer1's balance
            let relayer2Balance0 = await signer2.getBalance();
            // relayer1 submits block 0
            await relayer1.addBlock(
                genesis.merkle_root,
                chain[0].merkle_root,
                {value: ethers.utils.parseEther(relayerCollateral)}
            )
            // relayer2 submits block 1
            newTimestamp = await time.latest() + disputeTime;
            await time.setNextBlockTimestamp(newTimestamp);
            let tx = await relayer2.addBlock(
                chain[0].merkle_root,
                chain[1].merkle_root,
                {value: ethers.utils.parseEther(relayerCollateral)}
            )
            // relayer1 submits blocks 2 to 6
            for (let i = 1; i < 6; i++) {
                newTimestamp = await time.latest() + disputeTime;
                await time.setNextBlockTimestamp(newTimestamp);
                await relayer1.addBlock(
                    chain[i].merkle_root,
                    chain[i+1].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            }
            // check relayer1's balance
            let relayer2Balance1 = await signer2.getBalance();

            // set the correct submissionGasUsed
            let txInfo = await tx.wait();
            await relay2.setSubmissionGasUsed(txInfo.cumulativeGasUsed)
            
            // check relay smart contract balance
            let relay2Balance0 = await relay2.availableTNT();
            expect(relay2Balance0).to.equal(BigNumber.from(0));

            // 2 queries go for block 0 which is finalized
            let fee = await relay2.getBlockUsageFee(chain[0].height, 0);
            for (let i = 0; i < 2; i++) {
                await user.checkTxProof(
                    "0x995fcdd8736564c08a9c0cd873729fb0e746e9530e168bae93dc0a53c1c2b15e",
                    chain[0].height,
                    "0xaa6c8fafbe800d8159d3a266ab3fec99a7aea5115baca77adfe4658d377ed9d9e23afa26ed94d660cb4ae98a3878de76641d82d4a95b39a2d549fe1d0dc3717a92a5829d173ebb5edebb57726a92ba6527ac27a49b11642cb390ef88d7ad2c8f65b07be3eafac4a7a40ec24835b7c4de496211ae40d603b27abe0f066691093fe99acfe9d27688865c341ea216316a693e76f0df978b9dbe971205861e741121",
                    0,
                    {value: fee}
                )
            }
            
            // check relay smart contract balance
            let relay2Balance1 = await relay2.availableTNT();
            expect(relay2Balance1).to.equal(fee.mul(2));

            // check relayer2's balance
            let relayer2Balance2 = await signer2.getBalance();
            
            // relayer1 submits block 7 (so block 6 gets verified and block 1 gets finalized and reward is paid to the relayer)
            newTimestamp = await time.latest() + disputeTime;
            await time.setNextBlockTimestamp(newTimestamp);
            await expect(
                relayer1.addBlock(
                    chain[6].merkle_root,
                    chain[7].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockFinalized");

            // check relayer2's balance
            let relayer2Balance3 = await signer2.getBalance();

            let relayerPays = relayer2Balance0.sub(relayer2Balance1);
            let relayerGets = relayer2Balance3.sub(relayer2Balance2);
            // the ratio is 104.99999 instead of 105 so we take the ceil to ignore the error of calculation
            expect(Math.ceil((relayerGets.mul(1000).div(relayerPays)).toNumber() / 10)).to.equal(105); // 105 = 100 + relayerPercentageFee
        });

        it('appends multiple blocks in one height', async () => {
            let newTimestamp;
            // add 1 block
            relay2.addBlock(
                genesis.merkle_root,
                chain[0].merkle_root,
                {value: ethers.utils.parseEther(relayerCollateral)}
            )
            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[1].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")
            // new block can be added even if a block in that height gets verified
            newTimestamp = await time.latest() + disputeTime;
            await time.setNextBlockTimestamp(newTimestamp);
            await expect(
                relay2.addBlock(
                    genesis.merkle_root,
                    chain[2].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")
        });
    });

    describe('#addBlockWithRetarget', async () => {
        /* eslint-disable-next-line camelcase */
        const { chain, oldPeriodStart } = RETARGET_CHAIN;

        beforeEach(async () => {
            // deploy relay contract
            relay2 = await relayFactory.deploy(
                chain[0].merkle_root,
                chain[0].height,
                oldPeriodStart.digest_le,
                chain[0].timestamp,
                chain[0].difficulty,
                mockTDT.address
            );
            // set params
            await relay2.setMinCollateralRelayer(minCollateralRelayer);
            await relay2.setDisputeTime(BigNumber.from(disputeTime));
            await relay2.setProofTime(BigNumber.from(proofTime));
            // add blocks up to target change
            for (let i = 0; i < 8; i++) {
                let newTimestamp = await time.latest() + disputeTime;
                await time.setNextBlockTimestamp(newTimestamp);
                await relay2.addBlock(
                    chain[i].merkle_root,
                    chain[i+1].merkle_root,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            }
        });

        it('appends new links to the chain with retarget', async () => {
            let newTimestamp = await time.latest() + disputeTime;
            await time.setNextBlockTimestamp(newTimestamp);
            await expect(
                relay2.addBlockWithRetarget(
                    chain[8].merkle_root,
                    chain[9].merkle_root,
                    chain[9].timestamp,
                    chain[9].difficulty,
                    {value: ethers.utils.parseEther(relayerCollateral)}
                )
            ).to.emit(relay2, "BlockAdded")

            expect(
                await relay2.findHeight(chain[9].merkle_root)
            ).to.equal(chain[9].height)

        });

        // it('errors if the smart contract is paused', async () => {
        //     // pause the relay1
        //     await relay2.pauseRelay();

        //     await expect(
        //         relay2.addBlockWithRetarget(
        //             '0x00',
        //             lastHeader.hex,
        //             headers
        //         )
        //     ).to.revertedWith("Pausable: paused")
        // });

    //     it('errors if the old period start header is unknown', async () => {

    //         await expect(
    //             relay2.addHeadersWithRetarget(
    //                 '0x00',
    //                 lastHeader.hex,
    //                 headers
    //             )
    //         ).to.revertedWith("Relay: bad args. Check header and array byte lengths.")

    //     });

    //     it('errors if the old period end header is unknown', async () => {

    //         await expect(
    //             relay2.addHeadersWithRetarget(
    //                 firstHeader.hex,
    //                 chain[15].hex,
    //                 headers
    //             )
    //         ).to.revertedWith("Relay: unknown block")

    //     });

    //     it('errors if the provided last header does not match records', async () => {

    //         await expect(
    //             relay2.addHeadersWithRetarget(
    //                 firstHeader.hex,
    //                 firstHeader.hex,
    //                 headers)
    //         ).to.revertedWith("Relay: wrong end height")

    //     });

    //     it('errors if the start and end headers are not exactly 2015 blocks apart', async () => {

    //         await expect(
    //             relay2.addHeadersWithRetarget(
    //                 lastHeader.hex,
    //                 lastHeader.hex,
    //                 headers
    //             )
    //         ).to.revertedWith("Relay: wrong start height")

    //     });

    //     it('errors if the retarget is performed incorrectly', async () => {
    //         const relayFactory = new Relay__factory(
    //             deployer
    //         );

    //         const tmprelay2 = await relayFactory.deploy(
    //             genesis.merkle_root,
    //             lastHeader.height, // This is a lie
    //             firstHeader.digest_le,
    //             ZERO_ADDRESS
    //         );

    //         await expect(
    //             tmprelay2.addHeadersWithRetarget(
    //                 firstHeader.hex,
    //                 genesis.merkle_root,
    //                 headers
    //             )
    //         ).to.revertedWith("Relay: invalid retarget")

    //     });
    });

    // describe('#provideProof', async () => {
    //     /* eslint-disable-next-line camelcase */
    //     const { chain, oldPeriodStart } = REGULAR_CHAIN;

    //     beforeEach(async () => {
    //         let target = getTargetFromDiff(chain[0].difficulty) // TODO: it is not equal to target in contract
    //         console.log(target);
    //         console.log(target.toString());
    //         // deploy relay contract
    //         relay2 = await relayFactory.deploy(
    //             chain[0].merkle_root,
    //             chain[0].height,
    //             oldPeriodStart.digest_le,
    //             chain[0].timestamp,
    //             target.toString(),
    //             mockTDT.address
    //         );
    //         // set params
    //         await relay2.setMinCollateralRelayer(minCollateralRelayer);
    //         await relay2.setDisputeTime(BigNumber.from(disputeTime));
    //         await relay2.setProofTime(BigNumber.from(proofTime));
    //     });

    //     it('can provide proof if not disputed', async () => {
    //         let relay2Signer1 = await relay2.connect(signer1);
    //         let relay2Signer2 = await relay2.connect(signer2);
    //         await relay2Signer1.addBlock(
    //             chain[0].merkle_root,
    //             chain[1].merkle_root,
    //             {value: ethers.utils.parseEther(relayerCollateral)}
    //         )
    //         let signer1Balance0 = await signer1.getBalance();
    //         let newTimestamp = await time.latest() + 10;
    //         await time.increaseTo(newTimestamp);
    //         await expect(
    //             relay2Signer2.provideProof(
    //                 chain[0].hex,
    //                 chain[1].hex
    //             )
    //         ).to.emit(relay2, "BlockVerified")
    //         let signer1Balance1 = await signer1.getBalance();
    //         console.log(signer1Balance0);
    //         console.log(signer1Balance1);
    //         // expect(signer1Balance1.sub(signer1Balance0)).to.equal(relayerCollateral)
    //     });

    //     it('can provide proof if disputed', async () => {
    //         // check it gets the reward (challenger collateral)
    //         // TODO
    //     });

    //     it('reverts with invalid inputs', async () => {
    //         // TODO
    //     });
    // });

    describe('#findHeight', async () => {
        const {chain, oldPeriodStart} = REGULAR_CHAIN;

        beforeEach(async () => {
        // deploy relay contract
        relay2 = await relayFactory.deploy(
            chain[0].merkle_root,
            chain[0].height,
            oldPeriodStart.digest_le,
            chain[0].timestamp,
            chain[0].difficulty,
            mockTDT.address
        );
        // set params
        await relay2.setMinCollateralRelayer(minCollateralRelayer);
        await relay2.setDisputeTime(BigNumber.from(disputeTime));
        await relay2.setProofTime(BigNumber.from(proofTime));

        // add blocks up to target change
        for (let i = 0; i < 6; i++) {
            let newTimestamp = await time.latest() + disputeTime;
            await time.setNextBlockTimestamp(newTimestamp);
            await relay2.addBlock(
                chain[i].merkle_root,
                chain[i+1].merkle_root,
                {value: ethers.utils.parseEther(relayerCollateral)}
            )
        }
        });

        it('errors on unknown blocks', async () => {
            await expect(
                relay2.findHeight(`0x${'00'.repeat(32)}`)
            ).to.revertedWith("Relay: unknown block")

        });

        it('finds height of known blocks', async () => {
            //  since there's only 6 blocks added
            for (let i = 1; i < 6; i++) {
                /* eslint-disable-next-line camelcase */
                const { merkle_root, height } = chain[i];
                /* eslint-disable-next-line no-await-in-loop */
                expect(
                    await relay2.findHeight(merkle_root)
                ).to.equal(height)
            }
        });
    });

    // describe('#ownerAddHeaders', async () => {
    //     /* eslint-disable-next-line camelcase */
    //     const { chain_header_hex, chain, genesis, orphan_562630 } = REGULAR_CHAIN;
    //     // const headerHex = chain.map(header=> header.hex);
    //     const headerHex = chain_header_hex;

    //     const headers = utils.concatenateHexStrings(headerHex.slice(0, 6));

    //     beforeEach(async () => {

    //         relay2 = await relayFactory.deploy(
    //             genesis.merkle_root,
    //             genesis.height,
    //             orphan_562630.digest_le,
    //             mockTDT.address
    //         );

    //         // initialize mock contract
    //         await setTDTbalanceOf(0);
    //         await setTDTtransfer(true);
    //     });

    //     it('appends new links to the chain and fires an event', async () => {

    //         // owner is the deployer
    //         let relayDeployer = await relay2.connect(deployer);

    //         expect(
    //             await relayDeployer.ownerAddHeaders(
    //                 genesis.merkle_root,
    //                 headers
    //             )
    //         ).to.emit(relay2, "BlockAdded")
    //     });

    //     it('only owner can call it', async () => {

    //         // signer1 is not the owner
    //         let relaySigner1 = await relay2.connect(signer1);

    //         await expect(
    //             relaySigner1.ownerAddHeaders(
    //                 genesis.merkle_root,
    //                 headers
    //             )
    //         ).revertedWith("Ownable: caller is not the owner")
    //     });

    //     it('can be called even when the relay1 is paused', async () => {

    //         let relayDeployer = await relay2.connect(deployer);

    //         await relayDeployer.pauseRelay();

    //         expect(
    //             await relayDeployer.ownerAddHeaders(
    //                 genesis.merkle_root,
    //                 headers
    //             )
    //         ).to.emit(relay2, "BlockAdded")
    //     });

    // });

    // describe('#ownerAddHeadersWithRetarget', async () => {

    //     /* eslint-disable-next-line camelcase */
    //     const { chain, chain_header_hex } = RETARGET_CHAIN;
    //     const headerHex = chain_header_hex;
    //     const genesis = chain[1];

    //     const firstHeader = RETARGET_CHAIN.oldPeriodStart;
    //     const lastHeader = chain[8];
    //     const preChange = utils.concatenateHexStrings(headerHex.slice(2, 9));
    //     const headers = utils.concatenateHexStrings(headerHex.slice(9, 15));

        
    //     beforeEach(async () => {
            
    //         relay2 = await relayFactory.deploy(
    //             genesis.merkle_root,
    //             genesis.height,
    //             firstHeader.digest_le,
    //             ZERO_ADDRESS
    //         );
    //         await relay2.ownerAddHeaders(genesis.merkle_root, preChange);
    //     });

    //     it('appends new links to the chain and fires an event', async () => {
    //         let relayDeployer = await relay2.connect(deployer);

    //         expect(
    //             await relayDeployer.ownerAddHeadersWithRetarget(
    //                 firstHeader.hex,
    //                 lastHeader.hex,
    //                 headers
    //             )
    //         ).to.emit(relay2, "BlockAdded")

    //         expect(
    //             await relayDeployer.findHeight(chain[10].digest_le)
    //         ).to.equal(lastHeader.height + 2)

    //     });

    //     it('only owner can call it', async () => {

    //         // signer1 is not the owner
    //         let relaySigner1 = await relay2.connect(signer1);

    //         await expect(
    //             relaySigner1.ownerAddHeadersWithRetarget(
    //                 firstHeader.hex,
    //                 lastHeader.hex,
    //                 headers
    //             )
    //         ).revertedWith("Ownable: caller is not the owner")
            
    //     });

    //     it('can be called even when the relay1 is paused', async () => {

    //         let relayDeployer = await relay2.connect(deployer);

    //         await relayDeployer.pauseRelay();

    //         expect(
    //             await relayDeployer.ownerAddHeadersWithRetarget(
    //                 firstHeader.hex,
    //                 lastHeader.hex,
    //                 headers
    //             )
    //         ).to.emit(relay2, "BlockAdded")

    //         expect(
    //             await relayDeployer.findHeight(chain[10].digest_le)
    //         ).to.equal(lastHeader.height + 2)
    //     });

    // });

});
