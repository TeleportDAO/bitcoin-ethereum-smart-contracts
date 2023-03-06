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
import {Relay__factory } from "../src/types/factories/Relay__factory";
import { deployMockContract, MockContract } from "@ethereum-waffle/mock-contract";
import { takeSnapshot, revertProvider } from "./block_utils";

function revertBytes32(input: any) {
    let output = input.match(/[a-fA-F0-9]{2}/g).reverse().join('')
    return output;
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
    let bitcoinRESTAPI: any;
    let merkleRoots: any;

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
        let _genesisHeader = await bitcoinRESTAPI.getHexBlockHeader(_genesisHeight);
        let _periodStart = await bitcoinRESTAPI.getHexBlockHash(_height - (_height % 2016));
        _genesisHeader = '0x' + _genesisHeader;
        _periodStart = '0x' + revertBytes32(_periodStart);

        const relay1 = await relayFactory.deploy(
            _genesisHeader,
            _heightBigNumber,
            _periodStart,
            ZERO_ADDRESS
        );

        return relay1;
    };

    const deployRelayWithGenesis = async (
        _genesisHeight: any,
        _genesisHeader: any,
        _periodStart: any,
        _signer?: Signer
    ): Promise<Relay> => {
        const relayFactory = new Relay__factory(
            _signer || deployer
        );

        let _heightBigNumber = BigNumber.from(_genesisHeight)
        _genesisHeader = '0x' + _genesisHeader;
        _periodStart = '0x' + revertBytes32(_periodStart);

        const relayTest = await relayFactory.deploy(
            _genesisHeader,
            _heightBigNumber,
            _periodStart,
            ZERO_ADDRESS
        );

        return relayTest;
    };

    // ------------------------------------
    // SCENARIOS:
    describe('Submitting block headers', async () => {

        it('check the owner', async function () {
            let theOwnerAddress = await relay1.owner()

            let theDeployerAddress = await deployer.getAddress();

            expect(theOwnerAddress).to.equal(theDeployerAddress);
        })

        it('submit old block headers', async function () {
            this.timeout(0);
            let startFrom = 31; // upon change, please also change _genesisHeight
            // submit block headers up to 100*2016
            for (let i = startFrom; i < 32; i++) {

                let merkleRootsNew = '0x';

                let blockHeaderOld = '';

                if (i == startFrom) {
                    blockHeaderOld = '0x' + merkleRoots[startFrom * 63];
                    for (let j = 1; j < 63; j++) {
                        blockHeadersNew = blockHeadersNew + merkleRoots[j + i*63];
                    }
                } else {
                    blockHeaderOld = '0x' + merkleRoots[i*63 - 1];
                    for (let j = 0; j < 63; j++) {
                        blockHeadersNew = blockHeadersNew + merkleRoots[j + i*63];
                    }
                }

                expect(
                    await relay1.addHeaders(
                        blockHeaderOld, // anchor header
                        blockHeadersNew // new header;
                    )
                ).to.emit(relay1, "BlockAdded")

            }

        });

        it('revert a block header with wrong PoW', async function () {
            let blockHeaderOld = merkleRoots[2013];
            blockHeaderOld = '0x' + blockHeaderOld;
            // below = blockheader[2014] with a different nonce
            let blockHeaderNew = '0x' + '02000000b9985b54b29f5244d2884e497a68523a6f8a3874dadc1db26804000000000000f3689bc987a63f3d9db84913a4521691b6292d46be11166412a1bb561159098f238e6b508bdb051a6ffb0278';
            
            await expect(
                relay1.addHeaders(
                    blockHeaderOld, // anchor header
                    blockHeaderNew // new header;
                )
            ).revertedWith('Relay: header work is insufficient')

        });

        it('revert a block header with wrong previous hash', async function () {
            let blockHeaderOld = merkleRoots[2013];
            blockHeaderOld = '0x' + blockHeaderOld;
            // below = blockheader[2014] with a different previous hash (equal to its own hash)
            let blockHeaderNew = '0x' + '0200000090750e6782a6a91bf18823869519802e76ee462f462e8fb2cc00000000000000f3689bc987a63f3d9db84913a4521691b6292d46be11166412a1bb561159098f238e6b508bdb051a6ffb0277';
            
            await expect(
                relay1.addHeaders(
                    blockHeaderOld, // anchor header
                    blockHeaderNew // new header;
                )
            ).revertedWith('Relay: headers do not form a consistent chain')

        });

        it('submit a block header for a new epoch with same target (addHeaders)', async () => {
            let blockHeaderOld = '0x' + merkleRoots[2015];
            // block header new has the same target as block header old
            let blockHeaderNew = "0x010000009d6f4e09d579c93015a83e9081fee83a5c8b1ba3c86516b61f0400000000000025399317bb5c7c4daefe8fe2c4dfac0cea7e4e85913cd667030377240cadfe93a4906b508bdb051a84297df7"

            await expect(
                relay1.addHeaders(
                    blockHeaderOld, // anchor header
                    blockHeaderNew // new header;
                )
            ).revertedWith('Relay: headers should be submitted by calling addHeadersWithRetarget')
        });

        it('submit a block header with new target (addHeaders => unsuccessful)', async () => {
            let blockHeaderOld = merkleRoots[2015];
            let blockHeaderNew = await bitcoinRESTAPI.getHexBlockHeader(100*2016);
            blockHeaderOld = '0x' + blockHeaderOld;
            blockHeaderNew = '0x' + blockHeaderNew;

            await expect(
                relay1.addHeaders(
                    blockHeaderOld, // anchor header
                    blockHeaderNew // new header;
                )
            ).revertedWith('Relay: unexpected retarget on external call')

        });

        it('submit a block header with new target', async () => {
            let newHeight = BigNumber.from(100*2016);
            let blockHeaderNew = await bitcoinRESTAPI.getHexBlockHeader(newHeight); // this is the new block header
        
            blockHeaderNew = '0x' + blockHeaderNew;
            let oldPeriodStartHeader = '0x' + merkleRoots[0];
            let oldPeriodEndHeader = '0x' + merkleRoots[2015];

            // First block of the new epoch gets submitted successfully
            expect(
                await relay1.addHeadersWithRetarget(
                    oldPeriodStartHeader,
                    oldPeriodEndHeader,
                    blockHeaderNew
                )
            ).to.emit(relay1, "BlockAdded")

            let blockHeaderNext = await bitcoinRESTAPI.getHexBlockHeader(newHeight.add(1))
            let currentHash = '0x' + blockHeaderNext.slice(8, 72);
    
            // Hash of the block is stored
            expect(
                await relay1.getBlockHeaderHash(newHeight, 0)
            ).to.equal(currentHash)
            // Height of the block is stored
            expect(
                await relay1.findHeight(currentHash)
            ).to.equal(newHeight)
        });

    });

    describe('Submitting block headers with forks', async () => {
        /* eslint-disable-next-line camelcase */
        const { bitcoinPeriodStart, bitcoinCash, bitcoin } = FORKEDCHAIN;
        // bitcoin[4] is the first forked block
        
        let relayTest: any;

        beforeEach(async () => {

            relayTest = await deployRelayWithGenesis(
                bitcoinCash[0].blockNumber,
                bitcoinCash[0].blockHeader,
                bitcoinPeriodStart.blockHash
            );

        });
        
        it('successfully create a fork', async function () {
            // submit the main fork
            for (let i = 1; i < 7; i++) {
                await relayTest.addHeaders(
                    '0x' + bitcoinCash[i - 1].blockHeader,
                    '0x' + bitcoinCash[i].blockHeader
                )
            }
            // submit the second fork
            // note: confirmation number = 3
            for (let i = 4; i < 7; i++) {
                expect(
                    await relayTest.addHeaders(
                        '0x' + bitcoin[i - 1].blockHeader,
                        '0x' + bitcoin[i].blockHeader
                    )
                ).to.emit(relayTest, "BlockAdded")
            }
        });

        it('not be able to submit too old block headers to form a fork', async function () {
            // submit the main fork
            for (let i = 1; i < 8; i++) {
                await relayTest.addHeaders(
                    '0x' + bitcoinCash[i - 1].blockHeader,
                    '0x' + bitcoinCash[i].blockHeader
                )
            }
            // submit the second fork
            // note: confirmation number = 3
            await expect(
                relayTest.addHeaders(
                    '0x' + bitcoin[3].blockHeader,
                    '0x' + bitcoin[4].blockHeader
                )
            ).revertedWith("Relay: block headers are too old")
        });

        it('successfully prune the chain', async function () {
            // submit the main fork
            for (let i = 1; i < 7; i++) {
                await relayTest.addHeaders(
                    '0x' + bitcoinCash[i - 1].blockHeader,
                    '0x' + bitcoinCash[i].blockHeader
                )
            }
            // submit the second fork
            // note: confirmation number = 3
            for (let i = 4; i < 7; i++) {
                await relayTest.addHeaders(
                    '0x' + bitcoin[i - 1].blockHeader,
                    '0x' + bitcoin[i].blockHeader
                )
            }
            // check that the fork exists on the relay1
            for (let i = 4; i < 7; i++) {
                expect(
                    await relayTest.getNumberOfSubmittedHeaders(
                        bitcoin[i].blockNumber
                    )
                ).equal(2);
            }

            // this block finalizes a block in the forked chain so the main chain should be pruned
            expect(
                await relayTest.addHeaders(
                    '0x' + bitcoin[6].blockHeader,
                    '0x' + bitcoin[7].blockHeader
                )
            ).to.emit(relayTest, "BlockFinalized")

            // no other block header has remained in the same height as the finalized block
            expect(await relayTest.getNumberOfSubmittedHeaders(bitcoin[4].blockNumber)).equal(1);
            // and that one block header belongs to the finalized chain (bitcoin)
            expect(await relayTest.getBlockHeaderHash(bitcoin[4].blockNumber, 0)).equal('0x' + revertBytes32(bitcoin[4].blockHash));
        });

        it('successfully emit FinalizedBlock', async function () {
            // submit the main fork
            for (let i = 1; i < 3; i++) {
                await relayTest.addHeaders(
                    '0x' + bitcoinCash[i - 1].blockHeader,
                    '0x' + bitcoinCash[i].blockHeader
                )
            }
            // blocks start getting finalized
            // note: confirmation number = 3
            for (let i = 3; i < 7; i++) {
                expect(
                    await relayTest.addHeaders(
                        '0x' + bitcoinCash[i - 1].blockHeader,
                        '0x' + bitcoinCash[i].blockHeader
                    )
                ).to.emit(relayTest, "BlockFinalized")
            }
            // submit the second fork
            // no new height is being added, so no block is getting finalized
            for (let i = 4; i < 7; i++) {
                await expect(
                    relayTest.addHeaders(
                        '0x' + bitcoin[i - 1].blockHeader,
                        '0x' + bitcoin[i].blockHeader
                    )
                ).to.not.emit(relayTest, "BlockFinalized")
            }
            // a new height gets added, so new block gets finalized
            expect(
                await relayTest.addHeaders(
                    '0x' + bitcoin[6].blockHeader,
                    '0x' + bitcoin[7].blockHeader
                )
            ).to.emit(relayTest, "BlockFinalized")
        });
    });

    describe('Unfinalizing a finalized block header', async () => {
        // default fanalization parameter is 3
        // oldChain = [478558, 478559, 478560, 478561, 478562, 478563]
        // newChain = [478558, 478559", 478560", 478561", 478562", 478563"]
        const periodStart = FORKEDCHAIN.bitcoinPeriodStart;
        const oldChain = FORKEDCHAIN.bitcoinCash;
        const newChain = FORKEDCHAIN.bitcoin;

        let relayTest: any;
        let snapshotId: any;

        beforeEach(async () => {
            snapshotId = await takeSnapshot(signer1.provider);

            // deploy bitcoin relay1 contract with block 478558 (index 0 is 478555)
            relayTest = await deployRelayWithGenesis(
                oldChain[3].blockNumber,
                oldChain[3].blockHeader,
                periodStart.blockHash
            );

            // finalize blocks 478558 and 478559
            await expect(
                relayTest.addHeaders(
                    "0x" + oldChain[3].blockHeader,
                    "0x" + oldChain[4].blockHeader + oldChain[5].blockHeader + 
                        oldChain[6].blockHeader + oldChain[7].blockHeader
                )
            ).to.emit(relayTest, "BlockFinalized").withArgs(
                478559,
                '0x' + revertBytes32(oldChain[4].blockHash),
                '0x' + revertBytes32(oldChain[3].blockHash),
                await deployer.getAddress(),
                0,
                0
            );

        });
        
        afterEach(async () => {
            await revertProvider(signer1.provider, snapshotId);
        });
        
        it('unfinalize block 478559 and finalize block 478559"', async function () {
            // pause relay1
            await relayTest.pauseRelay();
            
            // increase finalization parameter from 3 to 4
            await relayTest.setFinalizationParameter(4);

            // submit new blocks [478559", 478560", 478561", 478562", 478563"] and finalize 478559"
            await expect(
                relayTest.ownerAddHeaders(
                    "0x" + oldChain[3].blockHeader,
                    "0x" + newChain[4].blockHeader + newChain[5].blockHeader + 
                        newChain[6].blockHeader + newChain[7].blockHeader + newChain[8].blockHeader,
                )
            ).to.emit(relayTest, "BlockFinalized").withArgs(
                478559,
                '0x' + revertBytes32(newChain[4].blockHash),
                '0x' + revertBytes32(newChain[3].blockHash),
                await deployer.getAddress(),
                0,
                0
            );
            
            // check that 478559 is removed and 478559" is added
            expect(
                relayTest.findHeight('0x' + revertBytes32(oldChain[4].blockHash))
            ).to.be.reverted;

            expect(
                await relayTest.findHeight('0x' + revertBytes32(newChain[4].blockHash))
            ).to.be.equal(478559);

        });

    });

    describe('Check tx inclusion', async () => {
        /* eslint-disable-next-line camelcase */
        const { block, transaction } = TXCHECK;

        it('errors if the smart contract is paused', async () => {

            let relayDeployer = await relay1.connect(deployer);
            let _height = block.height;
            // Get the fee amount needed for the query
            let fee = await relay1.getBlockHeaderFee(_height, 0);
            // pause the relay1
            await relayDeployer.pauseRelay();

            await expect(
                relayDeployer.checkTxProof(
                    transaction.tx_id,
                    block.height,
                    transaction.intermediate_nodes,
                    transaction.index,
                    {value: fee}
                )
            ).to.revertedWith("Pausable: paused")
            
            // unpause the relay1
            await relayDeployer.unpauseRelay();
        });

        it('transaction id should be non-zero',async() => {
            let relaySigner1 = await relay1.connect(signer1);
            let _height = block.height;
            // Get the fee amount needed for the query
            let fee = await relay1.getBlockHeaderFee(_height, 0);

            // See if the transaction check goes through successfully
            await expect(
                relaySigner1.checkTxProof(
                    "0x0000000000000000000000000000000000000000000000000000000000000000",
                    block.height,
                    transaction.intermediate_nodes,
                    transaction.index,
                    {value: fee}
                )
            ).revertedWith("Relay: txid should be non-zero")
        });

        it('errors if the requested block header is not on the relay1 (it is too old)', async () => {

            let relayDeployer = await relay1.connect(deployer);
            let _height = block.height;
            // Get the fee amount needed for the query
            let fee = await relay1.getBlockHeaderFee(_height, 0);

            await expect(
                relayDeployer.checkTxProof(
                    transaction.tx_id,
                    block.height - 100,
                    transaction.intermediate_nodes,
                    transaction.index,
                    {value: fee}
                )
            ).to.revertedWith("Relay: the requested height is not submitted on the relay1 (too old)")

        });

        it('check transaction inclusion -> when included',async() => {
            let relaySigner1 = await relay1.connect(signer1);
            // Get parameters before sending the query
            let relayETHBalance0 = await relay1.availableTNT();
            let currentEpochQueries0 = await relaySigner1.currentEpochQueries();
            let _height = block.height;
            // Get the fee amount needed for the query
            let fee = await relay1.getBlockHeaderFee(_height, 0);

            // See if the transaction check goes through successfully
            expect(
                await relaySigner1.callStatic.checkTxProof(
                    transaction.tx_id,
                    _height,
                    transaction.intermediate_nodes,
                    transaction.index,
                    {value: fee}
                )
            ).equal(true);
            // Actually change the state
            await relaySigner1.checkTxProof(
                transaction.tx_id,
                _height,
                transaction.intermediate_nodes,
                transaction.index,
                {value: fee}
            )
            
            let currentEpochQueries1 = await relaySigner1.currentEpochQueries();
            // Check if the number of queries is being counted correctly for fee calculation purposes
            expect(currentEpochQueries1.sub(currentEpochQueries0)).to.equal(1);

            let relayETHBalance1 = await relay1.availableTNT();
            // Expected fee should be equal to the contract balance after tx is processed
            expect(relayETHBalance1.sub(relayETHBalance0)).to.equal(fee);
        });

        it('reverts when enough fee is not paid',async() => {
            let relaySigner1 = await relay1.connect(signer1);
            // Get parameters before sending the query
            let relayETHBalance0 = await relay1.provider.getBalance(relay1.address);
            let currentEpochQueries0 = await relaySigner1.currentEpochQueries();
            let _height = block.height;
            // Get the fee amount needed for the query
            let fee = await relay1.getBlockHeaderFee(_height, 0);

            // See if the transaction check fails
            await expect(
                relaySigner1.checkTxProof(
                    transaction.tx_id,
                    _height,
                    transaction.intermediate_nodes,
                    transaction.index,
                    {value: fee.sub(1)}
                )
            ).revertedWith("Relay: fee is not enough")
            
            let currentEpochQueries1 = await relaySigner1.currentEpochQueries();
            // Check if the number of queries is being counted correctly for fee calculation purposes
            expect(currentEpochQueries1.sub(currentEpochQueries0)).to.equal(0);

            let relayETHBalance1 = await relay1.provider.getBalance(relay1.address);
            // Contract balance doesn't change
            expect(relayETHBalance1).equal(relayETHBalance0);
        });

        it('check transaction inclusion -> when not included',async() => {
            let relaySigner1 = await relay1.connect(signer1);
            // Get parameters before sending the query
            let relayETHBalance0 = await relay1.provider.getBalance(relay1.address);
            let currentEpochQueries0 = await relaySigner1.currentEpochQueries();
            let _height = block.height;
            // Get the fee amount needed for the query 
            let fee = await relay1.getBlockHeaderFee(_height, 0);

            // See if the transaction check returns false
            expect(
                await relaySigner1.callStatic.checkTxProof(
                    transaction.tx_id,
                    _height - 1,
                    transaction.intermediate_nodes,
                    transaction.index,
                    {value: fee}
                )
            ).equal(false);
            // Actually change the state
            await relaySigner1.checkTxProof(
                transaction.tx_id,
                _height - 1,
                transaction.intermediate_nodes,
                transaction.index,
                {value: fee}
            )
            
            let currentEpochQueries1 = await relaySigner1.currentEpochQueries();
            // Check if the number of queries is being counted correctly for fee calculation purposes
            expect(currentEpochQueries1.sub(currentEpochQueries0)).to.equal(1);

            let relayETHBalance1 = await relay1.provider.getBalance(relay1.address);
            // Expected fee should be equal to the contract balance after tx is processed
            expect(relayETHBalance1.sub(relayETHBalance0)).to.equal(fee);
        });

        it("reverts when tx's block is not finalized",async() => {
            let relaySigner1 = await relay1.connect(signer1);
            // Get parameters before sending the query
            let relayETHBalance0 = await relay1.provider.getBalance(relay1.address);
            let currentEpochQueries0 = await relaySigner1.currentEpochQueries();
            let _height = block.height;
            // Get the fee amount needed for the query 
            let fee = await relay1.getBlockHeaderFee(_height, 0);

            // See if the transaction check returns false
            await expect(
                relaySigner1.checkTxProof(
                    transaction.tx_id,
                    _height + 1,
                    transaction.intermediate_nodes,
                    transaction.index,
                    {value: fee}
                )
            ).revertedWith("Relay: block is not finalized on the relay1");
            
            let currentEpochQueries1 = await relaySigner1.currentEpochQueries();

            // Check if the number of queries is being counted correctly for fee calculation purposes
            expect(currentEpochQueries1.sub(currentEpochQueries0)).to.equal(0);

            let relayETHBalance1 = await relay1.provider.getBalance(relay1.address);

            // Expected fee should be equal to the contract balance after tx is processed
            expect(relayETHBalance1).equal(relayETHBalance0);
        });

    });

    // ------------------------------------
    // FUNCTIONS:
    describe('#constructor', async () => {
        /* eslint-disable-next-line camelcase */
        const { genesis, orphan_562630 } = REGULAR_CHAIN;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                orphan_562630.digest_le,
                ZERO_ADDRESS
            );
        });

        it('errors if the caller is being an idiot', async () => {

            await expect(
                relayFactory.deploy(
                    '0x00',
                    genesis.height,
                    genesis.digest_le,
                    ZERO_ADDRESS
                )
            ).to.revertedWith("Relay: stop being dumb")
        });

        it('errors if the period start is in wrong byte order', async () => {

            await expect(
                relayFactory.deploy(
                    genesis.hex,
                    genesis.height,
                    orphan_562630.digest,
                    ZERO_ADDRESS
                )
            ).to.revertedWith("Hint: wrong byte order?")
        });

        it('stores genesis block info', async () => {

            expect(
                await relay2.relayGenesisHash()
            ).to.equal(genesis.digest_le)

            expect(
                await relay2.findAncestor(
                    genesis.digest_le,
                    0
                )
            ).to.equal(genesis.digest_le)

            expect(
                await relay2.findHeight(genesis.digest_le)
            ).to.equal(genesis.height)
        });
    });

    describe('#pauseRelay', async () => {
        /* eslint-disable-next-line camelcase */
        const { genesis, orphan_562630 } = REGULAR_CHAIN;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                orphan_562630.digest_le,
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
                genesis.hex,
                genesis.height,
                orphan_562630.digest_le,
                ZERO_ADDRESS
            );
        });

        it('errors if the caller is not owner', async () => {

            let relaySigner1 = await relay2.connect(signer1);
            let relayDeployer = await relay2.connect(deployer);
            // owner pauses the relay1
            await relayDeployer.pauseRelay();

            await expect(
                relaySigner1.unpauseRelay()
            ).to.revertedWith("Ownable: caller is not the owner")
        });
    });

    describe('#getBlockHeaderHash', async () => {
        /* eslint-disable-next-line camelcase */
        const { chain, genesis, orphan_562630 } = REGULAR_CHAIN;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                orphan_562630.digest_le,
                ZERO_ADDRESS
            );
        });

        it('views the hash correctly', async () => {
            const header = chain[0].hex;
            expect(
                await relay2.addHeaders(genesis.hex, header)
            ).to.emit(relay2, "BlockAdded")
            expect(
                await relay2.getBlockHeaderHash(chain[0].height, 0)
            ).to.equal(chain[0].digest_le)
        });

    });

    describe('## Setters', async () => {
        /* eslint-disable-next-line camelcase */
        const { genesis, orphan_562630 } = REGULAR_CHAIN;
        let relaySigner2: any;

        beforeEach(async () => {
            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                orphan_562630.digest_le,
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
            ).withArgs(3, 6);

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

    });

    describe('#addHeaders', async () => {
        /* eslint-disable-next-line camelcase */
        const { chain_header_hex, chain, genesis, orphan_562630 } = REGULAR_CHAIN;
        // const headerHex = chain.map(header=> header.hex);
        const headerHex = chain_header_hex;

        const headers = utils.concatenateHexStrings(headerHex.slice(0, 6));

        beforeEach(async () => {

            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                orphan_562630.digest_le,
                mockTDT.address
            );

        });

        it('errors if the smart contract is paused', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            // pause the relay1
            await relay2.pauseRelay();

            await expect(
                relay2.addHeaders(
                    '0x00',
                    headers
                )
            ).to.revertedWith("Pausable: paused")
        });

        it('errors if the anchor is unknown', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            await expect(
                relay2.addHeaders(
                    '0x00',
                    headers
                )
            ).to.revertedWith("Relay: anchor must be 80 bytes")
        });

        it('errors if it encounters a retarget on an external call', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            let badHeaders = '0x0000002073bd2184edd9c4fc76642ea6754ee40136970efc10c4190000000000000000000296ef123ea96da5cf695f22bf7d94be87d49db1ad7ac371ac43c4da4161c8c216349c5ba11928170d38782b0000002073bd2184edd9c4fc76642ea6754ee40136970efc10c4190000000000000000005af53b865c27c6e9b5e5db4c3ea8e024f8329178a79ddb39f7727ea2fe6e6825d1349c5ba1192817e2d951590000002073bd2184edd9c4fc76642ea6754ee40136970efc10c419000000000000000000c63a8848a448a43c9e4402bd893f701cd11856e14cbbe026699e8fdc445b35a8d93c9c5ba1192817b945dc6c00000020f402c0b551b944665332466753f1eebb846a64ef24c71700000000000000000033fc68e070964e908d961cd11033896fa6c9b8b76f64a2db7ea928afa7e304257d3f9c5ba11928176164145d0000ff3f63d40efa46403afd71a254b54f2b495b7b0164991c2d22000000000000000000f046dc1b71560b7d0786cfbdb25ae320bd9644c98d5c7c77bf9df05cbe96212758419c5ba1192817a2bb2caa00000020e2d4f0edd5edd80bdcb880535443747c6b22b48fb6200d0000000000000000001d3799aa3eb8d18916f46bf2cf807cb89a9b1b4c56c3f2693711bf1064d9a32435429c5ba1192817752e49ae0000002022dba41dff28b337ee3463bf1ab1acf0e57443e0f7ab1d000000000000000000c3aadcc8def003ecbd1ba514592a18baddddcd3a287ccf74f584b04c5c10044e97479c5ba1192817c341f595';

            await expect(
                relay2.addHeaders(
                    genesis.hex,
                    badHeaders
                )
            ).to.revertedWith("Relay: unexpected retarget on external call")
        });

        it('errors if the header array is not a multiple of 80 bytes', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            let badHeaders = headers.substring(0, 8 + 5 * 160)

            await expect(
                relay2.addHeaders(
                    genesis.hex,
                    badHeaders
                )
            ).to.revertedWith("Relay: header array length must be divisible by 80")
        });

        it('errors if a header work is too low', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            let badHeaders = `${headers}${'00'.repeat(80)}`

            await expect(
                relay2.addHeaders(
                    genesis.hex,
                    badHeaders
                )
            // ).to.revertedWith("Relay: header work is insufficient")
            ).to.reverted; // above should be uncommented when a proper input is given
            // now it reverts before being catched in the expect that we want -> it has invalid target

        });

        it('errors if the target changes mid-chain', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            let badHeaders = utils.concatenateHexStrings([headers, REGULAR_CHAIN.badHeader.hex]);

            await expect(
                relay2.addHeaders(
                    genesis.hex,
                    badHeaders
                )
            ).to.revertedWith("Relay: target changed unexpectedly")

        });

        it('errors if a prevhash link is broken', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            let badHeaders = utils.concatenateHexStrings([headers, chain[15].hex]);

            await expect(
                relay2.addHeaders(
                    genesis.hex,
                    badHeaders
                )
            ).to.revertedWith("Relay: headers do not form a consistent chain")

        });

        it('appends new links to the chain and fires an event', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            expect(
                await relay2.addHeaders(
                    genesis.hex,
                    headers
                )
            ).to.emit(relay2, "BlockAdded")
        });

        it("contract has no TNT but doesn't revert when paying a relayer", async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            let relay2Balance0 = await relay2.provider.getBalance(relay2.address);
            expect(relay2Balance0).to.equal(BigNumber.from(0));
            expect(
                await relay2.addHeaders(
                    genesis.hex,
                    headers
                )
            ).to.emit(relay2, "BlockAdded")
            .and.emit(relay2, "BlockFinalized")
            let relay2Balance1 = await relay2.provider.getBalance(relay2.address);
            expect(relay2Balance1).to.equal(BigNumber.from(0));
        });

        it("contract has no TNT but has some TDT so rewards relayer only in TDT", async () => {
            const rewardAmountInTDTtest = 100;
            await relay2.setRewardAmountInTDT(rewardAmountInTDTtest);
            // initialize mock contract
            await setTDTbalanceOf(2 * rewardAmountInTDTtest);
            expect (await relay2.availableTDT()).equal(2 * rewardAmountInTDTtest)
            await setTDTtransfer(true);

            expect(
                await relay2.addHeaders(
                    genesis.hex,
                    headers
                )
            ).to.emit(relay2, "BlockAdded")
            .and.emit(relay2, "BlockFinalized")
        });

        it("fails in sending reward in TDT but submission goes through successfully", async () => {
            const rewardAmountInTDTtest = 100;
            await relay2.setRewardAmountInTDT(rewardAmountInTDTtest);
            // initialize mock contract
            await setTDTbalanceOf(2 * rewardAmountInTDTtest);
            await setTDTtransfer(false);

            await expect(
                relay2.addHeaders(
                    genesis.hex,
                    headers
                )
            ).to.revertedWith("SafeERC20: ERC20 operation did not succeed")
            // TODO: what's a favorable functionality? to be reverted or passed?
            // ).to.emit(relay2, "BlockAdded")
            // .and.emit(relay2, "BlockFinalized")
        });

        it("contract has enough TNT so pays the relayer", async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            let relayer1 = await relay2.connect(signer1);
            let relayer2 = await relay2.connect(signer3);
            let user = await relay2.connect(signer2);

            // submit blocks 0 to 3
            await relayer1.addHeaders(
                genesis.hex,
                chain[0].hex
            )

            // check relayer2's balance
            let relayerBalance0 = await signer3.getBalance();

            // relayer adds block 1
            let tx = await relayer2.addHeaders(
                chain[0].hex,
                chain[1].hex
            )
            
            // check relayer2's balance
            let relayerBalance1 = await signer3.getBalance();

            // set the correct submissionGasUsed
            let txInfo = await tx.wait();
            await relay2.setSubmissionGasUsed(txInfo.cumulativeGasUsed)

            // relayer adds blocks 2 and 3
            for (let i = 2; i < 4; i++) {
                await expect(
                    relayer1.addHeaders(
                        chain[i - 1].hex,
                        chain[i].hex
                    )
                ).to.emit(relay2, "BlockAdded")
            }
            
            // check relay1 smart contract balance
            let relay2Balance0 = await relay2.provider.getBalance(relay2.address);
            expect(relay2Balance0).to.equal(BigNumber.from(0));

            // 2 queries go for block 0 which is finalized
            let fee = await relay2.getBlockHeaderFee(chain[0].height, 0);
            for (let i = 0; i < 2; i++) {
                await user.checkTxProof(
                    "0x995fcdd8736564c08a9c0cd873729fb0e746e9530e168bae93dc0a53c1c2b15e",
                    chain[0].height,
                    "0xaa6c8fafbe800d8159d3a266ab3fec99a7aea5115baca77adfe4658d377ed9d9e23afa26ed94d660cb4ae98a3878de76641d82d4a95b39a2d549fe1d0dc3717a92a5829d173ebb5edebb57726a92ba6527ac27a49b11642cb390ef88d7ad2c8f65b07be3eafac4a7a40ec24835b7c4de496211ae40d603b27abe0f066691093fe99acfe9d27688865c341ea216316a693e76f0df978b9dbe971205861e741121",
                    0,
                    {value: fee}
                )
            }
            
            // check relay1 smart contract balance
            let relay2Balance1 = await relay2.provider.getBalance(relay2.address);
            expect(relay2Balance1).to.equal(fee.mul(2));

            // check relayer2's balance
            let relayerBalance2 = await signer3.getBalance();

            // submit block 4 (so block 1 gets finalized and reward is paid to the relayer)
            expect(
                await relayer1.addHeaders(
                    chain[3].hex,
                    chain[4].hex
                )
            ).emit(relay2, "BlockFinalized")

            // check relayer2's balance
            let relayerBalance3 = await signer3.getBalance();

            let relayerPays = relayerBalance0.sub(relayerBalance1);
            let relayerGets = relayerBalance3.sub(relayerBalance2);
            // the ratio is 104.99999 instead of 105 so we take the ceil to ignore the error of calculation
            expect(Math.ceil((relayerGets.mul(1000).div(relayerPays)).toNumber() / 10)).to.equal(105); // 105 = 100 + relayerPercentageFee
        });

        it('skips some validation steps for known blocks', async () => {
            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);

            const oneMoreHeader = utils.concatenateHexStrings([headers, headerHex[6]]);
            await relay2.addHeaders(genesis.hex, oneMoreHeader);
        });
    });

    describe('#addHeadersWithRetarget', async () => {
        const { chain, chain_header_hex } = RETARGET_CHAIN;
        const headerHex = chain_header_hex;
        const genesis = chain[1];

        const firstHeader = RETARGET_CHAIN.oldPeriodStart;
        const lastHeader = chain[8];
        const preChange = utils.concatenateHexStrings(headerHex.slice(2, 9));
        const headers = utils.concatenateHexStrings(headerHex.slice(9, 15));

        beforeEach(async () => {

            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                firstHeader.digest_le,
                ZERO_ADDRESS
            );

            await relay2.addHeaders(genesis.hex, preChange);

        });

        it('errors if the smart contract is paused', async () => {
            // pause the relay1
            await relay2.pauseRelay();

            await expect(
                relay2.addHeadersWithRetarget(
                    '0x00',
                    lastHeader.hex,
                    headers
                )
            ).to.revertedWith("Pausable: paused")
        });

        it('errors if the old period start header is unknown', async () => {

            await expect(
                relay2.addHeadersWithRetarget(
                    '0x00',
                    lastHeader.hex,
                    headers
                )
            ).to.revertedWith("Relay: bad args. Check header and array byte lengths.")

        });

        it('errors if the old period end header is unknown', async () => {

            await expect(
                relay2.addHeadersWithRetarget(
                    firstHeader.hex,
                    chain[15].hex,
                    headers
                )
            ).to.revertedWith("Relay: unknown block")

        });

        it('errors if the provided last header does not match records', async () => {

            await expect(
                relay2.addHeadersWithRetarget(
                    firstHeader.hex,
                    firstHeader.hex,
                    headers)
            ).to.revertedWith("Relay: must provide the last header of the closing difficulty period")

        });

        it('errors if the start and end headers are not exactly 2015 blocks apart', async () => {

            await expect(
                relay2.addHeadersWithRetarget(
                    lastHeader.hex,
                    lastHeader.hex,
                    headers
                )
            ).to.revertedWith("Relay: must provide exactly 1 difficulty period")

        });

        it('errors if the retarget is performed incorrectly', async () => {
            const relayFactory = new Relay__factory(
                deployer
            );

            const tmprelay2 = await relayFactory.deploy(
                genesis.hex,
                lastHeader.height, // This is a lie
                firstHeader.digest_le,
                ZERO_ADDRESS
            );

            await expect(
                tmprelay2.addHeadersWithRetarget(
                    firstHeader.hex,
                    genesis.hex,
                    headers
                )
            ).to.revertedWith("Relay: invalid retarget provided")

        });

        it('appends new links to the chain', async () => {
            await relay2.addHeadersWithRetarget(
                firstHeader.hex,
                lastHeader.hex,
                headers
            );

            expect(
                await relay2.findHeight(chain[10].digest_le)
            ).to.equal(lastHeader.height + 2)

        });
    });

    describe('#findHeight', async () => {
        const { genesis, chain, chain_header_hex, oldPeriodStart } = REGULAR_CHAIN;
        const headerHex = chain_header_hex;
        const headers = utils.concatenateHexStrings(headerHex.slice(0, 6));

        beforeEach(async () => {

            relay3 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                oldPeriodStart.digest_le,
                ZERO_ADDRESS
            );

            await relay3.addHeaders(genesis.hex, headers);
        });

        it('errors on unknown blocks', async () => {

            await expect(
                relay3.findHeight(`0x${'00'.repeat(32)}`)
            ).to.revertedWith("Relay: unknown block")

        });

        it('finds height of known blocks', async () => {
            //  since there's only 6 blocks added
            for (let i = 1; i < 6; i += 1) {
                /* eslint-disable-next-line camelcase */
                const { digest_le, height } = chain[i];

                /* eslint-disable-next-line no-await-in-loop */
                expect(
                    await relay3.findHeight(digest_le)
                ).to.equal(height)

            }
        });
    });

    describe('#findAncestor', async () => {
        const { chain, genesis, chain_header_hex, oldPeriodStart } = REGULAR_CHAIN;
        const headerHex = chain_header_hex;
        const headers = utils.concatenateHexStrings(headerHex.slice(0, 6));

        beforeEach(async () => {

            relay3 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                // FIXME: must pass the first block of the block period (2016)
                oldPeriodStart.digest_le,
                ZERO_ADDRESS
            );

            await relay3.addHeaders(genesis.hex, headers);
        });

        it('errors on unknown blocks', async () => {

            await expect(
                relay3.findAncestor(`0x${'00'.repeat(32)}`, 3)
            ).to.revertedWith("Relay: unknown ancestor")

        });

        it('Finds known ancestors based on on offsets', async () => {
            //  since there's only 6 blocks added
            for (let i = 0; i < 6; i += 1) {
                /* eslint-disable-next-line camelcase */
                const { digest_le } = chain[i];
                // console.log("i", i);
                // console.log("chain[i]: ", chain[i]);

                /* eslint-disable-next-line no-await-in-loop */
                let res = await relay3.findAncestor(digest_le, 0);
                expect(
                    res
                ).to.equal(digest_le)

                // assert.equal(res, digest_le);

                if (i > 0) {
                    /* eslint-disable-next-line no-await-in-loop */
                    res = await relay3.findAncestor(digest_le, 1);
                    expect(
                        res
                    ).to.equal(chain[i - 1].digest_le)

                    // assert.equal(res, chain[i - 1].digest_le);
                }
            }
        });

    });

    describe('#isAncestor', async () => {
        const { chain, genesis, chain_header_hex, oldPeriodStart } = REGULAR_CHAIN;
        const headerHex = chain_header_hex;
        const headers = utils.concatenateHexStrings(headerHex.slice(0, 6));

        before(async () => {

            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                oldPeriodStart.digest_le,
                ZERO_ADDRESS
            );
            await relay2.addHeaders(genesis.hex, headers);
        });

        it('returns false if it exceeds the limit', async () => {

            expect(
                await relay2.isAncestor(
                    genesis.digest_le, chain[3].digest_le, 1
                )
            ).to.equal(false);

        });

        it('finds the ancestor if within the limit', async () => {

            expect(
                await relay2.isAncestor(
                    genesis.digest_le, chain[3].digest_le, 5
                )
            ).to.equal(true);

        });
    });

    describe('#ownerAddHeaders', async () => {
        /* eslint-disable-next-line camelcase */
        const { chain_header_hex, chain, genesis, orphan_562630 } = REGULAR_CHAIN;
        // const headerHex = chain.map(header=> header.hex);
        const headerHex = chain_header_hex;

        const headers = utils.concatenateHexStrings(headerHex.slice(0, 6));

        beforeEach(async () => {

            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                orphan_562630.digest_le,
                mockTDT.address
            );

            // initialize mock contract
            await setTDTbalanceOf(0);
            await setTDTtransfer(true);
        });

        it('appends new links to the chain and fires an event', async () => {

            // owner is the deployer
            let relayDeployer = await relay2.connect(deployer);

            expect(
                await relayDeployer.ownerAddHeaders(
                    genesis.hex,
                    headers
                )
            ).to.emit(relay2, "BlockAdded")
        });

        it('only owner can call it', async () => {

            // signer1 is not the owner
            let relaySigner1 = await relay2.connect(signer1);

            await expect(
                relaySigner1.ownerAddHeaders(
                    genesis.hex,
                    headers
                )
            ).revertedWith("Ownable: caller is not the owner")
        });

        it('can be called even when the relay1 is paused', async () => {

            let relayDeployer = await relay2.connect(deployer);

            await relayDeployer.pauseRelay();

            expect(
                await relayDeployer.ownerAddHeaders(
                    genesis.hex,
                    headers
                )
            ).to.emit(relay2, "BlockAdded")
        });

    });

    describe('#ownerAddHeadersWithRetarget', async () => {

        /* eslint-disable-next-line camelcase */
        const { chain, chain_header_hex } = RETARGET_CHAIN;
        const headerHex = chain_header_hex;
        const genesis = chain[1];

        const firstHeader = RETARGET_CHAIN.oldPeriodStart;
        const lastHeader = chain[8];
        const preChange = utils.concatenateHexStrings(headerHex.slice(2, 9));
        const headers = utils.concatenateHexStrings(headerHex.slice(9, 15));

        
        beforeEach(async () => {
            
            relay2 = await relayFactory.deploy(
                genesis.hex,
                genesis.height,
                firstHeader.digest_le,
                ZERO_ADDRESS
            );
            await relay2.ownerAddHeaders(genesis.hex, preChange);
        });

        it('appends new links to the chain and fires an event', async () => {
            let relayDeployer = await relay2.connect(deployer);

            expect(
                await relayDeployer.ownerAddHeadersWithRetarget(
                    firstHeader.hex,
                    lastHeader.hex,
                    headers
                )
            ).to.emit(relay2, "BlockAdded")

            expect(
                await relayDeployer.findHeight(chain[10].digest_le)
            ).to.equal(lastHeader.height + 2)

        });

        it('only owner can call it', async () => {

            // signer1 is not the owner
            let relaySigner1 = await relay2.connect(signer1);

            await expect(
                relaySigner1.ownerAddHeadersWithRetarget(
                    firstHeader.hex,
                    lastHeader.hex,
                    headers
                )
            ).revertedWith("Ownable: caller is not the owner")
            
        });

        it('can be called even when the relay1 is paused', async () => {

            let relayDeployer = await relay2.connect(deployer);

            await relayDeployer.pauseRelay();

            expect(
                await relayDeployer.ownerAddHeadersWithRetarget(
                    firstHeader.hex,
                    lastHeader.hex,
                    headers
                )
            ).to.emit(relay2, "BlockAdded")

            expect(
                await relayDeployer.findHeight(chain[10].digest_le)
            ).to.equal(lastHeader.height + 2)
        });

    });

});
