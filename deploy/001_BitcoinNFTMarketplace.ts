import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';
import verify from "../helper-functions";
import config from 'config';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const {deployments, getNamedAccounts, network} = hre;
    const {deploy} = deployments;
    const { deployer } = await getNamedAccounts();

    const relay = config.get("relay");
    const transferDeadline = config.get("bitcoin_nft_marketplace.transfer_deadline");
    const protocolFee = config.get("bitcoin_nft_marketplace.protocol_percentage_fee");
    const treasury = config.get("treasury");
    const isSignRequired = config.get("bitcoin_nft_marketplace.sign_required");

    const theArgs = [
        relay,
        transferDeadline,
        protocolFee,
        treasury,
        isSignRequired
    ];

    const deployedContract = await deploy("BitcoinNFTMarketplace", {
        from: deployer,
        log: true,
        skipIfAlreadyDeployed: true,
        args: theArgs
    });

    if (network.name != "hardhat" && process.env.ETHERSCAN_API_KEY && process.env.VERIFY_OPTION == "1") {
        await verify(
            deployedContract.address, 
            [
                relay,
                transferDeadline,
                protocolFee, 
                treasury,
                isSignRequired
            ], 
            "contracts/marketplace/BitcoinNFTMarketplace.sol:BitcoinNFTMarketplace"
        );
    }
    
};

export default func;
func.tags = ["BitcoinNFTMarketplace"];
