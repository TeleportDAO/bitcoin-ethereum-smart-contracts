const { ethers } = require("ethers");
const bitcoin = require("bitcoinjs-lib");
const ecc = require("@bitcoinerlab/secp256k1");
const { randomBytes } = require('crypto')
const secp256k1 = require('secp256k1')
const arrayify = ethers.utils.arrayify;

function main() {
	bitcoin.initEccLib(ecc);
	let privKey = Buffer.from("e6d782aa4884ccb8bfb4646e29abe7b4e309d434552e6176296af834d8de0aea", "hex");
	var publicKey = secp256k1.publicKeyCreate(privKey);
	console.log("taproot address: ", createTaprootAddress(publicKey));

    var m = Buffer.from("d312e22b7e2dad1e2802031600213fbca8b1e0286c84a3ca9690fe592e28bd1a", "hex"); // message
	var sig = sign(m, privKey); 
	console.log("taproot pub key: ",  Buffer.from(publicKey.slice(1, 33).buffer).toString('hex'));
	console.log("msg: ", Buffer.from(arrayify(m).buffer).toString('hex'))
	console.log("v: ", (publicKey[0] - 2 + 27).toString());
	console.log("r: ", Buffer.from(sig.e.buffer).toString('hex'));
	console.log("s: ", (sig.s).toString('hex'));
}

function taprootPrivKey(pubKey, privKey, script) { // all inputs are buffers
	// taproot privKey = privKey + H(pubKey || script)
	let tweak = bitcoin.crypto.taggedHash(
		"TapTweak", 
		Buffer.concat(script ? [pubKey.slice(1, 33), script] : [pubKey])
	);
	return ecc.privateAdd(
        privKey,
        tweak,
    );
}

function createTaprootAddress(publicKey) {
	// Derive the Taproot script that will be used to create the address
	const taproot_script = bitcoin.payments.p2tr({
		pubkey: Buffer.from(publicKey.slice(1, 33).buffer)
	});
	return taproot_script.address;
}

function sign(m, privKey) {
	var publicKey = secp256k1.publicKeyCreate(privKey);

	// R = G * k
	var k = randomBytes(32);
	var R = secp256k1.publicKeyCreate(k);

	// e = h(address(R) || compressed pubkey || m)
	var e = challenge(R, m, publicKey);

	// xe = privKey * e
	var xe = secp256k1.privateKeyTweakMul(privKey, e);

	// s = k + xe
	var s = secp256k1.privateKeyTweakAdd(k, xe);
	return {R, s, e};
}

function challenge(R, m, publicKey) {
	// convert R to address
	// see https://github.com/ethereum/go-ethereum/blob/eb948962704397bb861fd4c0591b5056456edd4d/crypto/crypto.go#L275
	var R_uncomp = secp256k1.publicKeyConvert(R, false);
	var R_addr = arrayify(ethers.utils.keccak256(R_uncomp.slice(1, 65))).slice(12, 32);

	// e = keccak256(address(R) || compressed publicKey || m)
	var e = arrayify(ethers.utils.solidityKeccak256(
		["address", "uint8", "bytes32", "bytes32"],
		[R_addr, publicKey[0] + 27 - 2, publicKey.slice(1, 33), m]));

	return e;
}

main();