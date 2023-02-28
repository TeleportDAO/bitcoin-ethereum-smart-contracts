const TEST_DATA = require('./test_fixtures/bitcoinNFTMarketplace.json');
import { expect } from "chai";
import { deployments, ethers } from "hardhat";
import { Signer, BigNumber, BigNumberish, BytesLike } from "ethers";
import { deployMockContract, MockContract } from "@ethereum-waffle/mock-contract";
import { Address } from "hardhat-deploy/types";
import {BitcoinNFTMarketplace} from "../src/types/BitcoinNFTMarketplace";
import {BitcoinNFTMarketplace__factory} from "../src/types/factories/BitcoinNFTMarketplace__factory";
import { takeSnapshot, revertProvider } from "./block_utils";
import { network } from "hardhat"

describe("BitcoinNFTMarketplace", async () => {
    let snapshotId: any;

    // Accounts
    let deployer: Signer;
    let signer1: Signer;
    let deployerAddress: Address;
    let signer1Address: Address;

    // Contracts
    let bitcoinNFTMarketplace: BitcoinNFTMarketplace;
    let bitcoinNFTMarketplaceSigner1: BitcoinNFTMarketplace;

    // Mock contracts
    let mockBitcoinRelay: MockContract;

    // Constants
    let ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
    let ONE_ADDRESS = "0x0000000000000000000000000000000000000011";
    let oneHundred = BigNumber.from(10).pow(8).mul(100)
    let TRANSFER_DEADLINE = 20

    let btcPublicKey = "0x03789ed0bb717d88f7d321a368d905e7430207ebbd82bd342cf11ae157a7ace5fd"
    let btcAddress = "mmPPsxXdtqgHFrxZdtFCtkwhHynGTiTsVh"

    let USER_SCRIPT_P2PKH = "0x12ab8dc588ca9d5787dde7eb29569da63c3a238c";
    let USER_SCRIPT_P2PKH_TYPE = 1; // P2PKH

    let USER_SCRIPT_P2WPKH = "0x751e76e8199196d454941c45d1b3a323f1433bd6";
    let USER_SCRIPT_P2WPKH_TYPE = 3; // P2WPKH

    before(async () => {

        [deployer, signer1] = await ethers.getSigners();
        signer1Address = await signer1.getAddress();
        deployerAddress = await deployer.getAddress();

        // Mocks contracts
    
        const bitcoinRelay = await deployments.getArtifact(
            "IBitcoinRelay"
        );
        mockBitcoinRelay = await deployMockContract(
            deployer,
            bitcoinRelay.abi
        )

        // mock finalization parameter
        await mockBitcoinRelay.mock.finalizationParameter.returns(5);

        // Deploys contracts
        bitcoinNFTMarketplace = await deployBitcoinNFTMarketplace();

        // Connects signer1 to bitcoinNFTMarketplace
        bitcoinNFTMarketplaceSigner1 = await bitcoinNFTMarketplace.connect(signer1);
    });

    const deployBitcoinNFTMarketplace = async (
        _signer?: Signer
    ): Promise<BitcoinNFTMarketplace> => {
        const bitcoinNFTMarketplaceFactory = new BitcoinNFTMarketplace__factory(
            _signer || deployer
        );

        const bitcoinNFTMarketplace = await bitcoinNFTMarketplaceFactory.deploy(
            mockBitcoinRelay.address,
            TRANSFER_DEADLINE
        );

        return bitcoinNFTMarketplace;
    };

    async function setRelayLastSubmittedHeight(blockNumber: number) {
        await mockBitcoinRelay.mock.lastSubmittedHeight.returns(blockNumber);
    }

    async function setRelayCheckTxProofReturn(isFinal: boolean, relayFee?: number) {
        await mockBitcoinRelay.mock.getBlockHeaderFee.returns(relayFee || 0); // Fee of relay
        await mockBitcoinRelay.mock.checkTxProof
            .returns(isFinal);
    }

    async function listNFT(satoshiIdx = TEST_DATA.listNFT.satoshiIdx) {
        await bitcoinNFTMarketplace.listNFT(
            TEST_DATA.listNFT.bitcoinPubKey,
            TEST_DATA.listNFT.scriptType,
            TEST_DATA.listNFT.r,
            TEST_DATA.listNFT.s,
            TEST_DATA.listNFT.v,
            {   version: TEST_DATA.listNFT.version,
                vin: TEST_DATA.listNFT.vin,
                vout: TEST_DATA.listNFT.vout,
                locktime: TEST_DATA.listNFT.locktime
            },
            TEST_DATA.listNFT.outputIdx,
            satoshiIdx
        )
    }

    async function putBid(btcScript = TEST_DATA.putBid.btcScript) {
        await bitcoinNFTMarketplaceSigner1.putBid(
            TEST_DATA.listNFT.txId,
            deployerAddress,
            btcScript,
            TEST_DATA.putBid.scriptType,
            {value: TEST_DATA.putBid.bidAmount}
        )
    }

    async function acceptBid(index: number) {
        await bitcoinNFTMarketplace.acceptBid(
            TEST_DATA.listNFT.txId,
            index
        )
    }


    describe("#listNFT", async () => {

        beforeEach(async () => {
            snapshotId = await takeSnapshot(signer1.provider);

        });

        afterEach(async () => {
            await revertProvider(signer1.provider, snapshotId);
        });

        it("List an NFT", async function () {
            await expect(
                bitcoinNFTMarketplace.listNFT(
                    TEST_DATA.listNFT.bitcoinPubKey,
                    TEST_DATA.listNFT.scriptType,
                    TEST_DATA.listNFT.r,
                    TEST_DATA.listNFT.s,
                    TEST_DATA.listNFT.v,
                    {   
                        version: TEST_DATA.listNFT.version,
                        vin: TEST_DATA.listNFT.vin,
                        vout: TEST_DATA.listNFT.vout,
                        locktime: TEST_DATA.listNFT.locktime
                    },
                    TEST_DATA.listNFT.outputIdx,
                    TEST_DATA.listNFT.satoshiIdx
                )
            ).to.emit(bitcoinNFTMarketplace, "NFTListed").withArgs(
                TEST_DATA.listNFT.txId,
                TEST_DATA.listNFT.outputIdx,
                TEST_DATA.listNFT.satoshiIdx,
                deployerAddress
            )
        })

        it("Reverts since public key is invalid", async function () {
            expect(
                bitcoinNFTMarketplace.listNFT(
                    "0x11111",
                    TEST_DATA.listNFT.scriptType,
                    TEST_DATA.listNFT.r,
                    TEST_DATA.listNFT.s,
                    TEST_DATA.listNFT.v,
                    {   version: TEST_DATA.listNFT.version,
                        vin: TEST_DATA.listNFT.vin,
                        vout: TEST_DATA.listNFT.vout,
                        locktime: TEST_DATA.listNFT.locktime
                    },
                    TEST_DATA.listNFT.outputIdx,
                    TEST_DATA.listNFT.satoshiIdx
                )
            ).to.revertedWith("Marketplace: invalid pub key")
        })

        it("Reverts since public key is wrong", async function () {
            expect(
                bitcoinNFTMarketplace.listNFT(
                    btcPublicKey,
                    TEST_DATA.listNFT.scriptType,
                    TEST_DATA.listNFT.r,
                    TEST_DATA.listNFT.s,
                    TEST_DATA.listNFT.v,
                    {   version: TEST_DATA.listNFT.version,
                        vin: TEST_DATA.listNFT.vin,
                        vout: TEST_DATA.listNFT.vout,
                        locktime: TEST_DATA.listNFT.locktime
                    },
                    TEST_DATA.listNFT.outputIdx,
                    TEST_DATA.listNFT.satoshiIdx
                )
            ).to.revertedWith("Marketplace: wrong pub key")
        })

        it("Reverts since script type is wrong", async function () {
            expect(
                bitcoinNFTMarketplace.listNFT(
                    TEST_DATA.listNFT.bitcoinPubKey,
                    3,
                    TEST_DATA.listNFT.r,
                    TEST_DATA.listNFT.s,
                    TEST_DATA.listNFT.v,
                    {   version: TEST_DATA.listNFT.version,
                        vin: TEST_DATA.listNFT.vin,
                        vout: TEST_DATA.listNFT.vout,
                        locktime: TEST_DATA.listNFT.locktime
                    },
                    TEST_DATA.listNFT.outputIdx,
                    TEST_DATA.listNFT.satoshiIdx
                )
            ).to.revertedWith("Marketplace: wrong pub key")
        })

        it("Reverts since script type is invalid", async function () {
            expect(
                bitcoinNFTMarketplace.listNFT(
                    TEST_DATA.listNFT.bitcoinPubKey,
                    0,
                    TEST_DATA.listNFT.r,
                    TEST_DATA.listNFT.s,
                    TEST_DATA.listNFT.v,
                    {   version: TEST_DATA.listNFT.version,
                        vin: TEST_DATA.listNFT.vin,
                        vout: TEST_DATA.listNFT.vout,
                        locktime: TEST_DATA.listNFT.locktime
                    },
                    TEST_DATA.listNFT.outputIdx,
                    TEST_DATA.listNFT.satoshiIdx
                )
            ).to.revertedWith("Marketplace: invalid type")
        })

        it("Reverts since signature is wrong", async function () {
            expect(
                bitcoinNFTMarketplace.listNFT(
                    TEST_DATA.listNFT.bitcoinPubKey,
                    TEST_DATA.listNFT.scriptType,
                    TEST_DATA.listNFT.r,
                    TEST_DATA.listNFT.r,
                    TEST_DATA.listNFT.v,
                    {   version: TEST_DATA.listNFT.version,
                        vin: TEST_DATA.listNFT.vin,
                        vout: TEST_DATA.listNFT.vout,
                        locktime: TEST_DATA.listNFT.locktime
                    },
                    TEST_DATA.listNFT.outputIdx,
                    TEST_DATA.listNFT.satoshiIdx
                )
            ).to.revertedWith("Marketplace: not nft owner")
        })

    });

    describe("#putBid", async () => {

        beforeEach(async () => {
            snapshotId = await takeSnapshot(signer1.provider);
            // list NFT
            await listNFT();
        });

        afterEach(async () => {
            await revertProvider(signer1.provider, snapshotId);
        });

        it("Put a bid", async function () {
            await expect(
                bitcoinNFTMarketplaceSigner1.putBid(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    TEST_DATA.putBid.btcScript,
                    TEST_DATA.putBid.scriptType,
                    {value: TEST_DATA.putBid.bidAmount}
                )
            ).to.emit(bitcoinNFTMarketplaceSigner1, "NewBid").withArgs(
                TEST_DATA.listNFT.txId,
                deployerAddress,
                signer1Address,
                TEST_DATA.putBid.btcScript,
                TEST_DATA.putBid.scriptType,
                TEST_DATA.putBid.bidAmount
            )
        })

        it("Reverts since bitcoin script is invalid", async function () {
            expect(
                bitcoinNFTMarketplaceSigner1.putBid(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    TEST_DATA.listNFT.bitcoinPubKey,
                    TEST_DATA.putBid.scriptType,
                    {value: TEST_DATA.putBid.bidAmount}
                )
            ).to.revertedWith("Marketplace: invalid script")
        })

        it("Reverts since script type is invalid", async function () {
            expect(
                bitcoinNFTMarketplaceSigner1.putBid(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    TEST_DATA.listNFT.btcScript,
                    6,
                    {value: TEST_DATA.putBid.bidAmount}
                )
            ).to.revertedWith("Marketplace: invalid script")
        })

        // TODO: test isSold = true

    });

    describe("#acceptBid", async () => {

        beforeEach(async () => {
            snapshotId = await takeSnapshot(signer1.provider);
            await listNFT(); // list NFT
            await putBid(); // put bid
            await setRelayLastSubmittedHeight(100);
        });

        afterEach(async () => {
            await revertProvider(signer1.provider, snapshotId);
        });

        it("Accept a bid", async function () {
            await expect(
                bitcoinNFTMarketplace.acceptBid(
                    TEST_DATA.listNFT.txId,
                    0
                )
            ).to.emit(bitcoinNFTMarketplace, "BidAccepted").withArgs(
                TEST_DATA.listNFT.txId,
                deployerAddress,
                0,
                100 + TRANSFER_DEADLINE
            )
        })

        it("Reverts since bid index is invalid", async function () {
            expect(
                bitcoinNFTMarketplace.acceptBid(
                    TEST_DATA.listNFT.txId,
                    1
                )
            ).to.revertedWith("Marketplace: invalid idx")
        })

        it("Reverts since already acceptd another bid", async function () {
            await putBid(); // put new bid
            await acceptBid(0); // accept bid with index 0
            expect(
                bitcoinNFTMarketplace.acceptBid(
                    TEST_DATA.listNFT.txId,
                    1
                )
            ).to.revertedWith("Marketplace: already accepted")
        })

    });

    describe("#revokeBid", async () => {

        beforeEach(async () => {
            snapshotId = await takeSnapshot(signer1.provider);
            await listNFT(); // list NFT
            await putBid(); // put bid
            await setRelayLastSubmittedHeight(100);
        });

        afterEach(async () => {
            await revertProvider(signer1.provider, snapshotId);
        });

        it("Revoke a bid", async function () {
            const oldBalance = await ethers.provider.getBalance(bitcoinNFTMarketplaceSigner1.address);

            await expect(
                bitcoinNFTMarketplaceSigner1.revokeBid(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    0
                )
            ).to.emit(bitcoinNFTMarketplaceSigner1, "BidRevoked").withArgs(
                TEST_DATA.listNFT.txId,
                deployerAddress,
                0
            )

            const newBalance = await ethers.provider.getBalance(bitcoinNFTMarketplaceSigner1.address);
            
            // check contract balance after revoking
            expect(
                oldBalance.sub(TEST_DATA.putBid.bidAmount)
            ).equal(newBalance, "Wrong balance")
        })

        it("Reverts since bid already revoked", async function () {
            expect(
                bitcoinNFTMarketplaceSigner1.revokeBid(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    0
                )
            ).to.revertedWith("Marketplace: not owner")
        })

        it("Reverts since deadline for withdrawal has not passed", async function () {
            await acceptBid(0); // accept bid with index 0
            expect(
                bitcoinNFTMarketplaceSigner1.revokeBid(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    0
                )
            ).to.revertedWith("Marketplace: deadline not passed")
        })

        it("Revoke bid after deadline", async function () {
            await acceptBid(0); // accept bid with index 0
            await setRelayLastSubmittedHeight(100 + TRANSFER_DEADLINE + 1);
            await expect(
                bitcoinNFTMarketplaceSigner1.revokeBid(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    0
                )
            ).to.emit(bitcoinNFTMarketplaceSigner1, "BidRevoked").withArgs(
                TEST_DATA.listNFT.txId,
                deployerAddress,
                0
            )
        })

    });

    describe("#sellNFT", async () => {

        beforeEach(async () => {
            snapshotId = await takeSnapshot(signer1.provider);
            await listNFT();
            await putBid();
            await setRelayLastSubmittedHeight(100);
            await acceptBid(0);
            await setRelayCheckTxProofReturn(true, 0); // mock checkTxProof
        });

        afterEach(async () => {
            await revertProvider(signer1.provider, snapshotId);
        });

        it("Sell NFT", async function () {
            const oldBalance = await ethers.provider.getBalance(bitcoinNFTMarketplace.address);

            await expect(
                await bitcoinNFTMarketplace.sellNFT(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    0,
                    {   
                        version: TEST_DATA.sellNFT.transferTxVersion,
                        vin: TEST_DATA.sellNFT.transferTxVin,
                        vout: TEST_DATA.sellNFT.transferTxVout,
                        locktime: TEST_DATA.sellNFT.transferTxLocktime
                    },
                    TEST_DATA.sellNFT.outputNFTIdx,
                    TEST_DATA.sellNFT.blockNumber,
                    TEST_DATA.sellNFT.intermediateNodes,
                    TEST_DATA.sellNFT.index,
                    [
                        {  
                            version: TEST_DATA.sellNFT.inputTxVersion,
                            vin: TEST_DATA.sellNFT.inputTxVin,
                            vout: TEST_DATA.sellNFT.inputTxVout,
                            locktime: TEST_DATA.sellNFT.inputTxLocktime
                        }
                    ]
                )
            ).to.emit(bitcoinNFTMarketplace, "NFTSold").withArgs(
                TEST_DATA.listNFT.txId,
                deployerAddress,
                0,
                TEST_DATA.sellNFT.transferTxId,
                TEST_DATA.sellNFT.outputNFTIdx,
                TEST_DATA.sellNFT.firstInputValue + TEST_DATA.listNFT.satoshiIdx
            )

            const newBalance = await ethers.provider.getBalance(bitcoinNFTMarketplace.address);

            // check contract balance after selling NFT
            expect(
                oldBalance.sub(TEST_DATA.putBid.bidAmount)
            ).equal(newBalance, "Wrong balance")
        })

        it("Reverts since input tx is invalid", async function () {

            expect(
                bitcoinNFTMarketplace.sellNFT(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    0,
                    {   
                        version: TEST_DATA.sellNFT.transferTxVersion,
                        vin: TEST_DATA.sellNFT.transferTxVin,
                        vout: TEST_DATA.sellNFT.transferTxVout,
                        locktime: TEST_DATA.sellNFT.transferTxLocktime
                    },
                    TEST_DATA.sellNFT.outputNFTIdx,
                    TEST_DATA.sellNFT.blockNumber,
                    TEST_DATA.sellNFT.intermediateNodes,
                    TEST_DATA.sellNFT.index,
                    [
                        {  
                            version: TEST_DATA.invalidInputTx.inputTxVersion,
                            vin: TEST_DATA.invalidInputTx.inputTxVin,
                            vout: TEST_DATA.invalidInputTx.inputTxVout,
                            locktime: TEST_DATA.invalidInputTx.inputTxLocktime
                        }
                    ]
                )
            ).to.revertedWith("Marketplace: outpoint != input tx")
        })

        it("Reverts since nft tx doesn't exist", async function () {

            expect(
                bitcoinNFTMarketplace.sellNFT(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    0,
                    {   
                        version: TEST_DATA.invalidTransferTx.transferTxVersion,
                        vin: TEST_DATA.invalidTransferTx.transferTxVin,
                        vout: TEST_DATA.invalidTransferTx.transferTxVout,
                        locktime: TEST_DATA.invalidTransferTx.transferTxLocktime
                    },
                    TEST_DATA.sellNFT.outputNFTIdx,
                    TEST_DATA.sellNFT.blockNumber,
                    TEST_DATA.sellNFT.intermediateNodes,
                    TEST_DATA.sellNFT.index,
                    [
                        {  
                            version: TEST_DATA.invalidInputTx.inputTxVersion,
                            vin: TEST_DATA.invalidInputTx.inputTxVin,
                            vout: TEST_DATA.invalidInputTx.inputTxVout,
                            locktime: TEST_DATA.invalidInputTx.inputTxLocktime
                        }
                    ]
                )
            ).to.revertedWith("Marketplace: outpoint != input tx")
        })

        it("Reverts since nft not transffered", async function () {
            await listNFT(1); // list with new satoshi index
            expect(
                bitcoinNFTMarketplace.sellNFT(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    0,
                    {   
                        version: TEST_DATA.sellNFT.transferTxVersion,
                        vin: TEST_DATA.sellNFT.transferTxVin,
                        vout: TEST_DATA.sellNFT.transferTxVout,
                        locktime: TEST_DATA.sellNFT.transferTxLocktime
                    },
                    TEST_DATA.sellNFT.outputNFTIdx,
                    TEST_DATA.sellNFT.blockNumber,
                    TEST_DATA.sellNFT.intermediateNodes,
                    TEST_DATA.sellNFT.index,
                    [
                        {  
                            version: TEST_DATA.sellNFT.inputTxVersion,
                            vin: TEST_DATA.sellNFT.inputTxVin,
                            vout: TEST_DATA.sellNFT.inputTxVout,
                            locktime: TEST_DATA.sellNFT.inputTxLocktime
                        }
                    ]
                )
            ).to.revertedWith("Marketplace: not transffered")
        })

        it("Reverts since nft transffered to another user", async function () {
            await putBid(TEST_DATA.putBid.anotherBtcScript);
            expect(
                bitcoinNFTMarketplace.sellNFT(
                    TEST_DATA.listNFT.txId,
                    deployerAddress,
                    1,
                    {   
                        version: TEST_DATA.sellNFT.transferTxVersion,
                        vin: TEST_DATA.sellNFT.transferTxVin,
                        vout: TEST_DATA.sellNFT.transferTxVout,
                        locktime: TEST_DATA.sellNFT.transferTxLocktime
                    },
                    TEST_DATA.sellNFT.outputNFTIdx,
                    TEST_DATA.sellNFT.blockNumber,
                    TEST_DATA.sellNFT.intermediateNodes,
                    TEST_DATA.sellNFT.index,
                    [
                        {  
                            version: TEST_DATA.sellNFT.inputTxVersion,
                            vin: TEST_DATA.sellNFT.inputTxVin,
                            vout: TEST_DATA.sellNFT.inputTxVout,
                            locktime: TEST_DATA.sellNFT.inputTxLocktime
                        }
                    ]
                )
            ).to.revertedWith("Marketplace: not transffered")
        })

    });

});