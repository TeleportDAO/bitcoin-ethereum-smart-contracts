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

    async function moveBlocks(amount: number) {
        for (let index = 0; index < amount; index++) {
          await network.provider.request({
            method: "evm_mine",
            params: [],
          })
        }
    }

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

    async function setRelayLastSubmittedHeight(blockNumber: number): Promise<void> {
        await mockBitcoinRelay.mock.lastSubmittedHeight.returns(blockNumber);
    }

    async function setRelayCheckTxProofReturn(isFinal: boolean, relayFee?: number): Promise<void> {
        await mockBitcoinRelay.mock.getBlockHeaderFee.returns(relayFee || 0); // Fee of relay
        await mockBitcoinRelay.mock.checkTxProof
            .returns(isFinal);
    }

    async function listNFT() {
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
            TEST_DATA.listNFT.satoshiIdx
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
            expect(
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
});