var bitcoin = require("@teleportdao/bitcoin");
var providers = require("@teleportdao/providers");

const bitcoinProvider = new providers.bitcoin.ApiProviders.BlockStream({});

async function main() {

    const rawTransferTx = await bitcoinProvider.getRawTransaction(
        'fb01e0e9423aef17f09ef32661dae831ba5df8d7b68431e3db3a4053298be823'
    );
    console.log("rawTransferTx \n", bitcoin.bitcoinUtils.parseRawTransaction(rawTransferTx), "\n");

    const rawInputTx = await bitcoinProvider.getRawTransaction(
        '3ce2942c454724047588789e1dd9d739ceb4e853d9f4ea880b26ffe86b762e8b'
    );
    console.log("rawInputTx \n", bitcoin.bitcoinUtils.parseRawTransaction(rawInputTx), "\n");

    const rawNFTTx = await bitcoinProvider.getRawTransaction(
        '25f00a47cb7c32f789cd7a1871931d3c181d0e5d9e76beb0b8710f04d9c515e9'
    );
    console.log("rawNFTTx \n", bitcoin.bitcoinUtils.parseRawTransaction(rawNFTTx), "\n");

    const rawNFTTxTaproot = await bitcoinProvider.getRawTransaction(
        '9b28be1d7ae1db1ed77414480e990af268decb3d490d688b9dbc38d04a45ed4d'
    );
    console.log("rawNFTTxTaproot \n", bitcoin.bitcoinUtils.parseRawTransaction(rawNFTTxTaproot), "\n");


}

main();

