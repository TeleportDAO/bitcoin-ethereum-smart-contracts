var bitcoin = require("@teleportdao/bitcoin");
var providers = require("@teleportdao/providers");

const bitcoinProvider = new providers.bitcoin.ApiProviders.BlockStream({});

async function main() {

    const realTx = await bitcoinProvider.getRawTransaction(
        '1abd282e59fe9096caa3846c28e0b1a8bc3f2100160302281ead2d7e2be212d3'
    );
    console.log("realTx \n", bitcoin.bitcoinUtils.parseRawTransaction(realTx), "\n");

}

main();

