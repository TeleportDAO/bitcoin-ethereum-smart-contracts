const { ethers } = require("ethers");
const { randomBytes } = require('crypto')
const secp256k1 = require('secp256k1')
const arrayify = ethers.utils.arrayify;

function main() {
	let privKey = Buffer.from("2fd7cab0970c692b4151d77a6aeebcae2a3284556cbfc6f182c571eccfc2424f", "hex");
	var publicKey = secp256k1.publicKeyCreate(privKey);
    var m = Buffer.from("d82ef1708b9707e72e7d1558234c42060370f6d51382d769d1024ebb52d65350", "hex"); // message
	var sig = sign(m, privKey); 
	console.log("pub key: ",  Buffer.from(publicKey.slice(1, 33).buffer).toString('hex'));
	console.log("msg: ", Buffer.from(arrayify(m).buffer).toString('hex'))
	console.log("v: ", (publicKey[0] - 2 + 27).toString());
	console.log("r: ", Buffer.from(sig.e.buffer).toString('hex'));
	console.log("s: ", (sig.s).toString('hex'));
}

function sign(m, x) {
	var publicKey = secp256k1.publicKeyCreate(x);

	// R = G * k
	var k = randomBytes(32);
	var R = secp256k1.publicKeyCreate(k);

	// e = h(address(R) || compressed pubkey || m)
	var e = challenge(R, m, publicKey);

	// xe = x * e
	var xe = secp256k1.privateKeyTweakMul(x, e);

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