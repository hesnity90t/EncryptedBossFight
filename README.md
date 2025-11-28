# Encrypted Boss Fight — fhEVM Raid

Turn-based boss fight on **Zama fhEVM**: the player HP, boss HP and hit results are stored and updated **fully encrypted on-chain**. The browser interacts with the contract through the **Zama Relayer** and only decrypts what the connected wallet is allowed to see.

This repository contains:

* **Solidity contract** `EncryptedBossFight.sol` — encrypted boss, per‑player encrypted HP and combat logic.
* **Single‑file frontend** (`index.html`) — glassmorphism UI with encrypted logs, built on top of a minimal `fheCore` wrapper.

> Language: UI & code comments in **English**, meta‑documentation can be in Russian.

---

## High‑level idea

* Owner configures an **encrypted boss**: `max HP`, `defense`, `attack` — all as `euint16`.
* Any wallet can **Join fight** with an encrypted initial HP.
* A player chooses **attack power** + spell and sends an **encrypted attack**.
* The contract updates **both HP values inside ciphertext** using fhEVM arithmetic.
* Frontend calls `userDecrypt` via Relayer to learn only:

  * player current HP;
  * boss current HP;
  * whether the last hit passed defense.
* UI visualises:

  * HP bars for player and boss;
  * last hit status (success / blocked);
  * battle result (victory / defeat / draw / in progress);
  * detailed encrypted logs.

---

## Tech stack

* **Solidity** (Zama fhEVM flavor, `FHE` / `euint16` / `ebool`).
* **Hardhat** for compilation / deployment.
* **Zama Relayer SDK**: `https://cdn.zama.org/relayer-sdk-js/0.3.0-5/relayer-sdk-js.js`.
* **Ethers v6** (browser‑side, via CDN) for contract interaction.
* **Vanilla HTML/CSS/JS** single page, no build step required for the frontend.

---

## Project structure

Exact layout can slightly differ, but the typical structure is:

```text
.
├── contracts/
│   └── EncryptedBossFight.sol
├── deploy/
│   └── 00_deploy_encrypted_boss_fight.ts   # or .js — Hardhat deploy script
├── frontend/
│   └── public/
│       └── index.html                      # full single‑file frontend
├── server.js                               # simple Express static server (optional)
├── hardhat.config.ts                       # Hardhat + fhEVM config
├── package.json
└── README.md
```

---

## Smart contract overview

The contract (simplified description):

* `configureBoss(bytes32 encMaxHp, bytes32 encDefense, bytes32 encAttack, bytes proof)`

  * Only owner.
  * Stores encrypted boss stats and resets current HP to `maxHp`.

* `joinFight(bytes32 encInitialHp, bytes proof)`

  * Encrypts a fresh HP state for `msg.sender`.
  * If a previous run existed, is overwritten (new game).

* `attackBoss(bytes32 encAttackPower, bytes32 encSpellId, bytes proof)`

  * Uses encrypted arithmetic (`FHE.add`, `FHE.sub`, `FHE.gt`, `FHE.select`) to compute damage and update:

    * player HP,
    * boss HP.
  * Produces encrypted `hitSuccess` flag.

* `getMyCombatState()` (view)

  * Returns **handles only**:

    * `hpHandle` (player HP),
    * `lastHitHandle` (hit success),
    * `joined` flag,
    * `hasLastResult` flag.

* `getBossHpHandles()` (view)

  * Returns boss `maxHpHandle` and `currentHpHandle`.

* `getBossMeta()` (view)

  * Returns `exists` flag (configured or not).

All encrypted arithmetic happens on-chain, the frontend never sees clear values unless the wallet is authorised to decrypt them via `userDecrypt`.

---

## Frontend overview

Frontend is a **single HTML file** (`frontend/public/index.html`) that:

1. Loads dependencies via CDN:

   * `ethers@6` (`BrowserProvider`, `Contract`),
   * `relayer-sdk-js` (`initSDK`, `createInstance`, `SepoliaConfig`, `generateKeypair`).
2. Implements a tiny `fheCore` wrapper (in the same file):

   * `configure({ contractAddress, abi })` — sets up contract + relayer URLs.
   * `connectWallet()` / `disconnectWallet()` / `autoConnectIfAuthorized()`.
   * `encryptUint16(value)` — wraps `createEncryptedInput().add16(value).encrypt()`.
   * `userDecryptHandles(handles)` — builds `UserDecryptRequest` (EIP‑712) and calls `relayer.userDecrypt(...)`.
   * `isOwner()` / `getState()` helpers.
3. Renders an **Encrypted Boss Fight** dashboard:

   * Player card — HP bar, initial HP, attack slider, spell chips, “Join fight” & “Attack boss” buttons.
   * Boss card — encrypted boss portrait, HP bar, owner config inputs.
   * Battle result banner — victory/defeat/draw/ongoing.
   * Encrypted logs console.
4. Keeps all state purely in browser memory — no backend.

All logic is written in TypeScript‑style JS with careful `BigInt` handling (no `Number`/`BigInt` mixing, JSON logging via `safeStringify`).

---

## Prerequisites

* **Node.js** ≥ 18
* **npm / pnpm / yarn**
* **MetaMask** (or any EIP‑1193 compatible wallet) installed in the browser
* Access to **Zama fhEVM Sepolia testnet** (RPCs provided by Zama tooling)

---

## Installation

```bash
# 1. Clone repo
git clone https://github.com/<your-org-or-user>/encrypted-boss-fight.git
cd encrypted-boss-fight

# 2. Install dependencies
npm install
# or
pnpm install
```

If you don’t use TypeScript, the Hardhat config may be in plain JS; commands stay the same.

---

## Hardhat: compile & deploy contract

1. Configure **network** in `hardhat.config.(ts|js)` — point it to Zama fhEVM Sepolia.

2. Compile & deploy:

```bash
npx hardhat clean
npx hardhat compile

# Example: deploy to sepolia
npx hardhat deploy --network sepolia
```

3. After deployment copy the contract address and

   * update `CONTRACT_ADDRESS` constant in `frontend/public/index.html`, or
   * put it into `.env` and inject into the frontend when building/serving.

> **Note**: make sure the Solidity file is compatible with the Zama fhEVM compiler version you are using.

---

## Running the frontend

The frontend is static and can be served by any HTTP(S) server. Two options are common:

### 1. Minimal Express server (included)

If `server.js` is present:

```bash
node server.js
```

Default configuration (can be overridden via `.env`):

* `PORT=3042`
* `HOST=0.0.0.0`
* Static root: `frontend/public/`

The server automatically sets:

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

These headers are required for Relayer SDK WASM/Workers.

Open the app in your browser:

```text
http://localhost:3042/
```

### 2. Any other static host

You can drop `index.html` into any HTTPS static host (Vercel, Netlify, S3+CloudFront, Nginx, …) as long as:

* The **COOP/COEP** headers are set:

  * `Cross-Origin-Opener-Policy: same-origin`
  * `Cross-Origin-Embedder-Policy: require-corp`
* The origin is allowed by the Zama Relayer (for public testnet this is usually fine).

---

## Relayer integration details

* SDK URL: `https://cdn.zama.org/relayer-sdk-js/0.3.0-5/relayer-sdk-js.js`

* Network preset: `SepoliaConfig` (testnet)

* Frontend uses **testnet relayer** by default:

  ```js
  const urls = {
    relayerUrl: "https://relayer.testnet.zama.org",
    gatewayUrl: "https://gateway.testnet.zama.org"
  };
  ```

* If you run a **local proxy** (recommended for some environments):

  * Set `relayerUrl = <origin>/relayer`, `gatewayUrl = <origin>/gateway`.
  * Optionally configure this via env or a small helper function.

### userDecrypt

For `userDecrypt`, the frontend:

1. Calls `generateKeypair()` in the browser.
2. Builds an EIP‑712 message with `relayer.createEIP712(...)`.
3. Signs it via `signer.signTypedData(...)` from the connected wallet.
4. Sends the signature, ephemeral keys and the list of `{ handle, contractAddress }` pairs to `relayer.userDecrypt(...)`.
5. Normalises the response with `buildValuePicker(...)` so the UI can do:

```js
const { pick } = await fheCore.userDecryptHandles(handles);
const myHp = pick(hpHandle);
const bossHp = pick(bossHpHandle);
```

All BigInt values are always converted with `normalizeDecryptedValue` (booleans mapped to `0n/1n`).

---

## Gameplay flow

1. **Connect wallet**

   * Click **Connect wallet**.
   * dApp connects MetaMask, auto‑switches to Sepolia if needed and initialises Relayer.

2. **Check boss status**

   * Top‑right pill shows `Boss ready` / `Boss not configured`.

3. **Owner: configure boss (admin panel)**

   * Only contract owner sees the admin block:

     * `Boss max HP`, `Defense`, `Attack` (all `uint16`).
   * Press **Configure encrypted boss**.
   * Frontend encrypts three values and sends them to `configureBoss`.

4. **Player: join the fight**

   * Choose `Initial HP`.
   * Press **Join fight**.
   * HP stored encrypted on contract; frontend decrypts snapshot and shows HP bar.

5. **Attack cycle**

   * Move **Attack power** slider.
   * Pick spell: **Basic Strike** or **Power Strike**.
   * Press **Attack boss**:

     * attack power + spell id are encrypted via Relayer;
     * contract computes damage fully inside ciphertext;
     * frontend calls `userDecrypt` to display:

       * updated player and boss HP,
       * whether the last hit was successful.

6. **End of fight**

   * UI shows a **battle result banner**:

     * Victory — boss HP reached zero.
     * Defeat — player HP reached zero.
     * Draw — both HP = 0.
   * To start a new run, player hits **Join fight** again with a fresh initial HP.

---

## Encrypted logs

At the bottom of the page there is a small console which shows human‑friendly logs for each step:

* `wallet: connecting…` / `wallet: connected.` / `wallet: disconnected.`
* `enc/boss: max=5000 def=1200 atk=400`.
* `enc/join: hp=5000`.
* `enc/attack: power=800 spell=1`.
* `tx/*: mined, refreshing encrypted state…`.
* `snapshot: you=3800 boss=0 hit=success`.

Errors from Relayer / RPC / userDecrypt are also surfaced in a compact form so debugging is easier.

---

## Known issues & troubleshooting

### Zama testnet relayer 5xx / CORS errors

You may sometimes see errors like:

* `POST https://relayer.testnet.zama.org/v1/input-proof net::ERR_FAILED 504/520`
* `No 'Access-Control-Allow-Origin' header is present on the requested resource`

These are usually **infrastructure issues on the public testnet relayer** or temporary CORS misconfiguration on Zama’s side.

What you can try:

1. Make sure the frontend is served from a single origin with correct COOP/COEP headers.
2. Retry later — when Zama’s infra is under maintenance, some endpoints may intermittently fail.
3. For production, consider running your own Relayer instance or a trusted proxy, following Zama’s documentation.

### MetaMask not found

If `window.ethereum` is missing, the app shows `Wallet not connected` and buttons are disabled.
Install MetaMask or another browser wallet which exposes EIP‑1193 provider.

### HP not updating

* Ensure the last transaction is mined (MetaMask shows it as confirmed).
* Check DevTools console for `userDecrypt` errors.
* If relayer responds but values look wrong, try **hard refresh** (clears in‑memory state) and re‑join the fight.

---

## Security / privacy notes

* This is a **testnet demo** to showcase Zama fhEVM capabilities — **not** production‑grade code.
* Encrypted values are handled carefully, but:

  * contract logic has not been formally audited;
  * DoS, griefing or economic attacks were not a focus.
* Never store or send secrets other than gameplay stats through this demo.

---

## Development tips

* Keep an eye on both:

  * Browser DevTools console (for frontend logs and Relayer errors).
  * Hardhat node / RPC logs (for contract calls and reverts).
* When changing contract ABI or address, make sure to update:

  * `CONTRACT_ADDRESS` in `index.html` (or environment),
  * `CONTRACT_ABI` array used by the frontend.
* If you fork this UI for other fhEVM games, you can:

  * reuse the minimal `fheCore` wrapper;
  * keep the HP bars / battle result components;
  * plug in your own encrypted contract calls and decryption logic.

---

## License

Specify a license for this project, for example:

```text
MIT
```

If you don’t include a license, the project is "all rights reserved" by default.
