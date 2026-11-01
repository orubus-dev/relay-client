// Produces sync-vault fixtures with WEB crypto (same code as relay's
// src/lib/sync/vaultCrypto.ts) for the Dart interop test.
const crypto = require("crypto").webcrypto;

const PBKDF2_ITERATIONS = 650_000;
const HKDF_INFO = "relay-sync-share-v1";
const enc = new TextEncoder();

function b64(bytes) { return Buffer.from(bytes).toString("base64"); }
function unb64(s) { return new Uint8Array(Buffer.from(s, "base64")); }
function b64u(bytes) { return Buffer.from(bytes).toString("base64url"); }
function unb64u(s) { return new Uint8Array(Buffer.from(s, "base64url")); }
const bs = (u8) => u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength);

async function main() {
  // 1) PBKDF2 wrap key + AES-GCM seal of the UK (like setupVault)
  const passphrase = "correct horse battery staple";
  const salt = unb64("MTIzNDU2Nzg5MGFiY2RlZg=="); // "1234567890abcdef"
  const wrapKey = await crypto.subtle.deriveKey(
    { name: "PBKDF2", salt: bs(salt), iterations: PBKDF2_ITERATIONS, hash: "SHA-256" },
    await crypto.subtle.importKey("raw", bs(enc.encode(passphrase)), "PBKDF2", false, ["deriveKey"]),
    { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
  const wrapKeyRaw = new Uint8Array(await crypto.subtle.exportKey("raw", wrapKey));

  const uk = crypto.getRandomValues(new Uint8Array(32));
  const ukIv = crypto.getRandomValues(new Uint8Array(12));
  const ukBox = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: bs(ukIv) }, wrapKey, bs(uk)));

  // 2) vault keypair + wrap a space key for the vault owner (share channel)
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const pubJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const privJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);

  async function channelKey(privJ, peerPubJ) {
    const priv = await crypto.subtle.importKey("jwk", privJ, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
    const pub = await crypto.subtle.importKey("jwk", peerPubJ, { name: "ECDH", namedCurve: "P-256" }, false, []);
    const bits = await crypto.subtle.deriveBits({ name: "ECDH", public: pub }, priv, 256);
    const hkdf = await crypto.subtle.importKey("raw", bits, "HKDF", false, ["deriveKey"]);
    return crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: bs(enc.encode(HKDF_INFO)), info: bs(enc.encode(HKDF_INFO)) },
      hkdf, { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
  }

  const spaceKey = crypto.getRandomValues(new Uint8Array(32));
  const eph = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const ephPrivJ = await crypto.subtle.exportKey("jwk", eph.privateKey);
  const ephPubJ = await crypto.subtle.exportKey("jwk", eph.publicKey);
  const channel = await channelKey(ephPrivJ, pubJwk);
  const shareIv = crypto.getRandomValues(new Uint8Array(12));
  const skWrap = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: bs(shareIv) }, channel, bs(spaceKey)));

  // 3) record: fresh record key wraps payload, space key wraps record key
  const rk = crypto.getRandomValues(new Uint8Array(32));
  const recIv = crypto.getRandomValues(new Uint8Array(12));
  const payload = enc.encode(JSON.stringify({ hello: "world", n: 42, web: true }));
  const recBox = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: bs(recIv) }, await crypto.subtle.importKey("raw", bs(rk), { name: "AES-GCM" }, false, ["encrypt"]), bs(payload)));
  const rkIv = crypto.getRandomValues(new Uint8Array(12));
  const rkBox = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: bs(rkIv) }, await crypto.subtle.importKey("raw", bs(spaceKey), { name: "AES-GCM" }, false, ["encrypt"]), bs(rk)));

  console.log(JSON.stringify({
    passphrase, salt_b64: b64(salt), wrap_key_raw_b64: b64(wrapKeyRaw),
    uk_b64: b64(uk), uk_iv_b64: b64(ukIv), uk_box_b64: b64(ukBox),
    vault_pub_jwk: pubJwk, vault_priv_jwk: privJwk,
    eph_pub_jwk: ephPubJ, share_iv_b64: b64(shareIv), sk_wrap_b64: b64(skWrap),
    space_key_b64: b64(spaceKey),
    rec_iv_b64: b64(recIv), rec_box_b64: b64(recBox),
    rk_iv_b64: b64(rkIv), rk_box_b64: b64(rkBox), payload: JSON.parse(new TextDecoder().decode(payload)),
  }, null, 1));
}
main().catch((e) => { console.error(e); process.exit(1); });
