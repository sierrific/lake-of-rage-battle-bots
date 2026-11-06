// A última reserva cai ao entrar (Stealth Rock, Spikes) depois das reposições da busca: a jogada
// tem de voltar como partida terminada, com o KO nas linhas (revisão de código de 06/11). Antes, o
// vencedor era lido antes das reposições e a jogada voltava "sem vencedor", com as linhas de antes.
//
// Roda sem o simulador: o sim_bridge.js do Ai-vgc com o patch, com Battle/State/PRNG simulados.
//
//   node reposicao_fim.cjs src/ai_vgc/nn/sim_bridge.js
'use strict';
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');

// Uma batalha de mentira: no turno, o Pokémon ativo deles desmaia; a reposição (a última
// reserva) entra e cai na hora com Stealth Rock, e a partida acaba.
class FakeBattle {
  constructor(lastFaintsOnEntry) {
    this.lastFaintsOnEntry = lastFaintsOnEntry;
    this.log = [];
    this.ended = false;
    this.winner = undefined;
    this.midTurn = false;
    this.chosen = {};
    this.sides = ['p1', 'p2'].map(id => ({
      id, active: [{fainted: false}, {fainted: false}], activeRequest: {wait: false},
      clearChoice() {},
    }));
  }
  getSide(id) { return this.sides.find(s => s.id === id); }
  choose(side, choice) {
    const s = this.getSide(side);
    if (s.activeRequest && s.activeRequest.forceSwitch) {
      s.activeRequest = {wait: false};
      this.log.push('|switch|p2a: Reserva|Reserva, L50|100/100');
      if (this.lastFaintsOnEntry) {
        this.log.push('|-damage|p2a: Reserva|0 fnt|[from] Stealth Rock', '|faint|p2a: Reserva', '|win|us');
        this.ended = true;
        this.winner = 'us';
        for (const x of this.sides) x.activeRequest = null;
      } else {
        for (const x of this.sides) x.activeRequest = {wait: false};  // o próximo turno
      }
      return true;
    }
    this.chosen[side] = choice;
    if (this.chosen.p1 && this.chosen.p2) {
      this.log.push('|move|p1a: Nosso|Close Combat|p2a: Deles', '|-damage|p2a: Deles|0 fnt', '|faint|p2a: Deles', '|upkeep');
      this.getSide('p2').activeRequest = {wait: false, forceSwitch: [true, false]};
      this.getSide('p1').activeRequest = {wait: true};
    }
    return true;
  }
}

let lastFaintsOnEntry = true;
const stubs = {
  battle: {Battle: class {}, extractChannelMessages: (text, chans) => ({[chans[0]]: text.split('\n')})},
  state: {State: {deserializeBattle: () => new FakeBattle(lastFaintsOnEntry), serializeBattle: () => ({})}},
  prng: {PRNG: class {}},
  readline: {createInterface: () => ({on() {}})},
};
const context = {
  require: name => stubs[name] || stubs[name.split('/').pop()] || require(name),
  process: {argv: ['node', 'sim_bridge.js', '/nao/existe'], stdout: {write() {}}},
  console,
};
vm.createContext(context);
vm.runInContext(source + '\nthis.play = play;', context);

const sides = {us: 'p1', them: 'p2'};
const [r] = context.play('{}', sides, [['move closecombat 1, move protect', 'move 1 1, move 2']], [1], true, true);
assert.strictEqual(r.err, '');
assert.strictEqual(r.winner, 'us', 'a jogada que termina a partida nas reposições voltou sem vencedor');
assert.ok(r.lines.some(l => l.startsWith('|faint|p2a: Reserva')), 'o KO da reserva ficou fora das linhas');
assert.ok(r.lines.some(l => l.startsWith('|win|')), 'o fim da partida ficou fora das linhas');
assert.strictEqual(r.next, undefined, 'uma partida terminada não continua para o segundo turno');

// Reposição que sobrevive: a jogada continua como antes (posição guardada para o segundo turno).
lastFaintsOnEntry = false;
const [s] = context.play('{}', sides, [['move closecombat 1, move protect', 'move 1 1, move 2']], [1], true, true);
assert.strictEqual(s.winner, null);
assert.ok(s.next && s.next.id >= 0, 'a posição depois da reposição devia ser guardada');
assert.ok(s.lines.some(l => l.startsWith('|switch|p2a: Reserva')));
console.log('reposicao_fim: ok');
