import test from 'node:test';
import assert from 'node:assert/strict';
import {calculate,REFERENCES} from '../references.js';
import {budgetTotals,SECTIONS} from '../mission.js';
test('battery sizing includes discharge efficiency and usable fraction',()=>assert.ok(Math.abs(calculate('battery',{power:100,hours:12,efficiency:.9,usable:.8})-1666.6666666666667)<1e-9));
test('invalid physical inputs fail rather than show Infinity',()=>{assert.throws(()=>calculate('battery',{power:100,hours:12,efficiency:0,usable:1}));assert.throws(()=>calculate('radiator',{heat:100,emissivity:.9,temperature:100,environment:200}));assert.throws(()=>calculate('solar',{power:100,irradiance:1361,efficiency:.2,derating:.8,angle:90}))});
test('known reference calculations',()=>{assert.equal(calculate('weight',{mass:100}),162);assert.equal(calculate('resources',{crew:4,days:30,rate:1,margin:20}),144);assert.ok(Math.abs(calculate('link',{distance:1,frequency:1})-92.44778322188338)<1e-8)});
test('budgets separate operating cases and unlike units, and exclude archives',()=>{const r=(category,unit,amount,margin,scenario,archived=false)=>({kind:'budgets',archived,data:{category,unit,amount,margin,scenario}});assert.deepEqual(budgetTotals([r('Mass','kg',100,20,'nominal'),r('Power','W',50,0,'nominal'),r('Power','W',90,0,'contingency'),r('Mass','kg',100,20,'nominal',true)]),{'nominal / Mass / kg':120,'nominal / Power / W':50,'contingency / Power / W':90})});
test('all requested sections exist and reference URLs are HTTPS',()=>{assert.equal(Object.keys(SECTIONS).length,11);assert.ok(REFERENCES.every(r=>new URL(r[2]).protocol==='https:'))});
