// Continuação da busca depois de desmaios (plano de regressão de 06/11): a jogada só segue para o
// segundo turno quando as reposições terminaram. Se uma reposição fica pendente, a posição não é
// guardada (a busca usa o valor de um turno) e nenhum lado recebe pedido de golpe com um slot ainda
// esperando troca. Com reposições dos dois lados, as duas entram (uma vez cada), e as entradas e as
// habilidades de entrada estão nas linhas do turno seguinte.
//
// Roda sem o simulador: o sim_bridge.js do Ai-vgc com o patch, com Battle/State/PRNG simulados.
//
//   node reposicao_pendente.cjs src/ai_vgc/nn/sim_bridge.js
'use strict';
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');

// mode: 'pending' (a troca padrão não resolve a reposição), 'both' (desmaio dos dois lados),
// 'one' (só o deles desmaia).
class FakeBattle {
  constructor(mode) {
    this.mode = mode;
    this.log = [];
    this.ended = false;
    this.winner = undefined;
    this.midTurn = false;
    this.chosen = {};
    this.defaults = {p1: 0, p2: 0};
    this.sides = ['p1', 'p2'].map(id => ({
      id, active: [{fainted: false}, {fainted: false}], activeRequest: {wait: false},
      clearChoice() {},
    }));
  }
  getSide(id) { return this.sides.find(s => s.id === id); }
  choose(side, choice) {
    const s = this.getSide(side);
    if (s.activeRequest && s.activeRequest.forceSwitch) {
      assert.strictEqual(choice, 'default');
      this.defaults[side]++;
      if (this.mode === 'pending') return false;  // a reposição não foi aceita
      const name = side === 'p1' ? 'p1a: Nossa Reserva' : 'p2a: Reserva';
      this.log.push(`|switch|${name}|Reserva, L50|100/100`, `|-ability|${name}|Intimidate|boost`);
      s.activeRequest = {wait: true};
      if (this.sides.every(x => !x.activeRequest.forceSwitch)) {
        for (const x of this.sides) x.activeRequest = {wait: false};  // o próximo turno
      }
      return true;
    }
    assert.ok(!(s.activeRequest && s.activeRequest.wait), `pedido de jogada para ${side}, que espera`);
    this.chosen[side] = choice;
    if (this.chosen.p1 && this.chosen.p2) {
      this.log.push('|move|p1a: Nosso|Close Combat|p2a: Deles', '|-damage|p2a: Deles|0 fnt', '|faint|p2a: Deles');
      if (this.mode === 'both') this.log.push('|-damage|p1a: Nosso|0 fnt|[from] Rocky Helmet', '|faint|p1a: Nosso');
      this.log.push('|upkeep');
      this.getSide('p2').activeRequest = {wait: false, forceSwitch: [true, false]};
      this.getSide('p1').activeRequest = this.mode === 'both' ? {wait: false, forceSwitch: [true, false]} : {wait: true};
    }
    return true;
  }
}

let mode = 'pending';
let last = null;
const stubs = {
  battle: {Battle: class {}, extractChannelMessages: (text, chans) => ({[chans[0]]: text.split('\n')})},
  state: {State: {deserializeBattle: () => (last = new FakeBattle(mode)), serializeBattle: () => ({})}},
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
const pair = [['move closecombat 1, move protect', 'move 1 1, move 2']];

// Reposição pendente: não continua, e o erro não some num estado "válido".
mode = 'pending';
const [p] = context.play('{}', sides, pair, [1], true, true);
assert.strictEqual(p.winner, null);
assert.strictEqual(p.next, undefined, 'uma reposição pendente não pode virar posição de segundo turno');
assert.ok(last.defaults.p2 >= 1 && last.defaults.p2 <= 4, 'tentativas de reposição sem limite');
assert.ok(!p.lines.some(l => l.startsWith('|switch|')), 'linhas de uma troca que não aconteceu');

// Sem "fill" (busca de um turno): nunca guarda uma posição com troca pendente.
mode = 'one';
const [n] = context.play('{}', sides, pair, [1], true, false);
assert.strictEqual(n.next, undefined, 'posição guardada com um slot ainda esperando troca');
assert.strictEqual(last.defaults.p2, 0, 'sem "fill" a busca não escolhe a reposição');

// Desmaio dos dois lados: cada lado repõe uma vez, e as entradas vão para as linhas.
mode = 'both';
const [b] = context.play('{}', sides, pair, [1], true, true);
assert.strictEqual(b.err, '');
assert.ok(b.next && b.next.id >= 0, 'a posição depois das duas reposições devia ser guardada');
assert.deepStrictEqual(last.defaults, {p1: 1, p2: 1}, 'cada lado devia repor exatamente uma vez');
for (const who of ['p1a: Nossa Reserva', 'p2a: Reserva']) {
  assert.ok(b.lines.some(l => l.startsWith(`|switch|${who}`)), `a entrada de ${who} ficou fora das linhas`);
  assert.ok(b.lines.some(l => l.startsWith(`|-ability|${who}`)), `a habilidade de entrada de ${who} ficou fora`);
}
console.log('reposicao_pendente: ok');
