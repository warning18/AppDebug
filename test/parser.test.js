const assert = require('assert');
const { parseLine } = require('../parser');
let e = parseLine('11-23 10:00:00.123  1234  1234 V FA      : Logging event (FE): add_to_cart(_ac), Bundle[{item_id=SKU1, price=9.99, currency=EUR, firebase_screen_class(_sc)=CartActivity}]');
assert.strictEqual(e.name, 'add_to_cart');
assert.strictEqual(e.params.price, '9.99');
assert.strictEqual(e.params.firebase_screen_class, 'CartActivity');
e = parseLine('11-23 10:00:00.1  1  1 V FA : Logging event: origin=app,name=login,params=Bundle[{method=google, note=a, b=c}]');
assert.strictEqual(e.name, 'login'); assert.strictEqual(e.params.note, 'a, b=c'.split(', ')[0]);
assert.strictEqual(parseLine('random line'), null);
console.log('parser ok');
const { createBatchParser } = require('../parser');
const p = createBatchParser(); const out = [];
const L = (m) => `11-23 10:00:01.500 V/FA-SVC(  999): ${m}`;
['event {','  name: "screen_view"','  param {','    name: "firebase_screen"','    string_value: "Home"','  }','  param {','    name: "engagement_time_msec"','    int_value: 1200','  }','}','End-of-batch']
  .forEach(l => out.push(...p.feed(L(l))));
assert.strictEqual(out[0].event.name, 'screen_view');
assert.strictEqual(out[0].event.params.firebase_screen, 'Home');
assert.strictEqual(out[0].event.params.engagement_time_msec, '1200');
assert.strictEqual(out[1].type, 'batch-end');
console.log('batch parser ok');

// ---- more samples
{
  const p2 = createBatchParser(); const o = [];
  const T = (m) => `11-23 10:00:02.250  1234  1234 V FA-SVC : ${m}`;           // threadtime
  ['event {','name: "purchase"','param {','name: "value"','double_value: 12.5','}','param {','name: "item_name"','string_value: "Blue shirt: size M, \\"slim\\""','}','}','End-of-batch']
    .forEach(l => o.push(...p2.feed(T(l))));
  assert.strictEqual(o[0].event.name, 'purchase');
  assert.strictEqual(o[0].event.params.value, '12.5');
  assert.strictEqual(o[0].event.params.item_name, 'Blue shirt: size M, \\"slim\\"');
  assert.strictEqual(o[1].type, 'batch-end');
  // two events in one batch, then lines from other tags are ignored
  const p3 = createBatchParser(); const r = [];
  const L2 = (m) => `11-23 10:00:03.000 V/FA-SVC(  1): ${m}`;
  ['event {','name: "a"','}','event {','name: "b"','}','Uploading data. app: x','End-of-batch'].forEach(l => r.push(...p3.feed(L2(l))));
  assert.deepStrictEqual(r.filter(x => x.type === 'event').map(x => x.event.name), ['a', 'b']);
  assert.strictEqual(r.filter(x => x.type === 'batch-end').length, 1);
  assert.deepStrictEqual(p3.feed('11-23 10:00:03.000 V/OtherTag(  1): event {'), []);
  const e = parseLine('11-23 10:00:00.1 V/FA( 99): Logging event (FE): select_content(_sc), Bundle[{}]');
  assert.strictEqual(e.name, 'select_content'); assert.deepStrictEqual(e.params, {});
  const u = parseLine('11-23 10:00:00.1 V/FA( 99): Setting user property (FE): tier(_tr), gold');
  assert.strictEqual(u.kind, 'user_property'); assert.strictEqual(u.params.value, 'gold');
  console.log('extra samples ok');
}
