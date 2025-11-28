// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
  FHE,
  ebool,
  euint16,
  externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * EncryptedBossFight (per-player boss HP)
 *
 * - Boss has global encrypted template: maxHp, defense, attack.
 * - Each player has:
 *      - encrypted HP (eHp),
 *      - their own encrypted boss HP (eBossHp),
 *      - encrypted lastHitSuccess flag.
 * - On joinFight:
 *      - player HP is set from encrypted input,
 *      - player boss HP is reset to boss.eMaxHp (new run).
 * - On attackBoss:
 *      - damage is applied to player.eBossHp,
 *      - boss counter-attacks player's eHp,
 *      - both values stay encrypted; player can decrypt via userDecrypt.
 */
contract EncryptedBossFight is ZamaEthereumConfig {
  // ---------------------------------------------------------------------------
  // Ownership
  // ---------------------------------------------------------------------------

  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // ---------------------------------------------------------------------------
  // Simple nonReentrant guard
  // ---------------------------------------------------------------------------

  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // ---------------------------------------------------------------------------
  // Boss configuration (encrypted template)
  // ---------------------------------------------------------------------------

  struct BossConfig {
    bool   exists;
    euint16 eMaxHp;
    euint16 eDefense;
    euint16 eAttack;
  }

  BossConfig private boss;

  event BossConfigured();

  function configureBoss(
    externalEuint16 encMaxHp,
    externalEuint16 encDefense,
    externalEuint16 encAttack,
    bytes calldata proof
  ) external onlyOwner {
    require(proof.length != 0, "missing proof");

    euint16 eMaxHp = FHE.fromExternal(encMaxHp, proof);
    euint16 eDefense = FHE.fromExternal(encDefense, proof);
    euint16 eAttack = FHE.fromExternal(encAttack, proof);

    // long-term ACL: contract itself
    FHE.allowThis(eMaxHp);
    FHE.allowThis(eDefense);
    FHE.allowThis(eAttack);

    boss.exists = true;
    boss.eMaxHp = eMaxHp;
    boss.eDefense = eDefense;
    boss.eAttack = eAttack;

    emit BossConfigured();
  }

  function getBossMeta() external view returns (bool exists) {
    return boss.exists;
  }

  /**
   * Per-caller HP handles:
   * - maxHpHandle: global boss max HP (template).
   * - currentHpHandle: this caller's current boss HP (eBossHp).
   *
   * If caller never joined, currentHpHandle will be zero-handle.
   */
  function getBossHpHandles()
    external
    view
    returns (bytes32 maxHpHandle, bytes32 currentHpHandle)
  {
    euint16 eBossHp = players[msg.sender].eBossHp;
    return (FHE.toBytes32(boss.eMaxHp), FHE.toBytes32(eBossHp));
  }

  // ---------------------------------------------------------------------------
  // Player state (encrypted)
  // ---------------------------------------------------------------------------

  struct PlayerState {
    euint16 eHp;             // player HP
    euint16 eBossHp;         // this player's personal boss HP
    ebool   eLastHitSuccess; // last attack result
    bool    joined;
    bool    hasLastResult;
  }

  mapping(address => PlayerState) private players;

  event PlayerJoined(
    address indexed player,
    bytes32 playerHpHandle,
    bytes32 bossHpHandle
  );

  event AttackResolved(
    address indexed player,
    bytes32 playerHpHandle,
    bytes32 bossHpHandle,
    bytes32 hitSuccessHandle
  );

  function joinFight(
    externalEuint16 encInitialHp,
    bytes calldata proof
  ) external nonReentrant {
    require(boss.exists, "Boss not configured");
    require(proof.length != 0, "proof required");

    PlayerState storage P = players[msg.sender];

    // player HP from encrypted input
    euint16 eHp = FHE.fromExternal(encInitialHp, proof);
    FHE.allowThis(eHp);
    FHE.allow(eHp, msg.sender);

    // personal boss HP starts from global max HP
    euint16 eBossHp = boss.eMaxHp;
    // make sure contract keeps ACL on template
    FHE.allowThis(eBossHp);
    // allow this player to decrypt their boss HP bar
    FHE.allow(eBossHp, msg.sender);
    FHE.allow(boss.eMaxHp, msg.sender);

    P.eHp = eHp;
    P.eBossHp = eBossHp;
    P.joined = true;
    P.hasLastResult = false;

    // keep long-term ACL
    FHE.allowThis(P.eHp);
    FHE.allowThis(P.eBossHp);

    emit PlayerJoined(
      msg.sender,
      FHE.toBytes32(P.eHp),
      FHE.toBytes32(P.eBossHp)
    );
  }

  function getMyCombatState()
    external
    view
    returns (
      bytes32 hpHandle,
      bytes32 lastHitHandle,
      bool joined,
      bool hasLastResult
    )
  {
    PlayerState storage P = players[msg.sender];
    return (
      FHE.toBytes32(P.eHp),
      FHE.toBytes32(P.eLastHitSuccess),
      P.joined,
      P.hasLastResult
    );
  }

  // ---------------------------------------------------------------------------
  // Combat
  // ---------------------------------------------------------------------------

  uint16 private constant SPELL_POWER_STRIKE = 1;

  function attackBoss(
    externalEuint16 encAttackPower,
    externalEuint16 encSpellId,
    bytes calldata proof
  ) external nonReentrant {
    require(boss.exists, "Boss not configured");

    PlayerState storage P = players[msg.sender];
    require(P.joined, "Player not in fight");
    require(proof.length != 0, "proof required");

    // Encrypted inputs
    euint16 eAttack = FHE.fromExternal(encAttackPower, proof);
    euint16 eSpell  = FHE.fromExternal(encSpellId, proof);

    FHE.allowThis(eAttack);
    FHE.allowThis(eSpell);
    FHE.allow(eAttack, msg.sender);
    FHE.allow(eSpell, msg.sender);

    // Spell logic: power strike +50% damage
    euint16 eHalfAttack   = FHE.div(eAttack, uint16(2));
    euint16 eBuffedAttack = FHE.add(eAttack, eHalfAttack);

    ebool isPowerStrike = FHE.eq(eSpell, SPELL_POWER_STRIKE);

    euint16 eEffectiveAttack = FHE.select(
      isPowerStrike,
      eBuffedAttack,
      eAttack
    );

    // Damage to boss if attack passes defense
    ebool   hitSuccess    = FHE.gt(eEffectiveAttack, boss.eDefense);
    euint16 eZero         = FHE.asEuint16(uint16(0));
    euint16 eDamageToBoss = FHE.select(hitSuccess, eEffectiveAttack, eZero);

    // Apply damage to this player's boss HP
    P.eBossHp = _applyDamage(P.eBossHp, eDamageToBoss);
    FHE.allowThis(P.eBossHp);
    FHE.allow(P.eBossHp, msg.sender);

    // Make sure player can always see template max HP
    FHE.allow(boss.eMaxHp, msg.sender);

    // Boss counter-attacks player's HP
    P.eHp = _applyDamage(P.eHp, boss.eAttack);
    FHE.allowThis(P.eHp);
    FHE.allow(P.eHp, msg.sender);

    // Last hit result (encrypted)
    P.eLastHitSuccess = hitSuccess;
    P.hasLastResult = true;

    FHE.allowThis(P.eLastHitSuccess);
    FHE.allow(P.eLastHitSuccess, msg.sender);

    emit AttackResolved(
      msg.sender,
      FHE.toBytes32(P.eHp),
      FHE.toBytes32(P.eBossHp),
      FHE.toBytes32(P.eLastHitSuccess)
    );
  }

  function _applyDamage(
  euint16 currentHp,
  euint16 damage
) internal returns (euint16) {
    ebool overkill = FHE.gt(damage, currentHp);

    euint16 clampedDamage = FHE.select(
      overkill,
      currentHp,
      damage
    );

    euint16 newHp = FHE.sub(currentHp, clampedDamage);
    return newHp;
}

}
