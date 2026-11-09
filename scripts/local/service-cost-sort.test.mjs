import assert from 'node:assert/strict'
import test from 'node:test'
import { sortServiceProductCosts } from '../../src/lib/serviceProductCostsSort.ts'

const row = (service_id, values = {}) => ({ service_id, service_name: service_id, is_active: true, unit_cost_ex_gst: null, effective_from: null, effective_to: null, seen_in_sales: false, first_sale_date: null, last_sale_date: null, ...values })
const ids = (rows) => rows.map((value) => value.service_id)
const sort = (rows, key, dir = 'asc', drafts = {}) => sortServiceProductCosts(rows, { key, dir }, drafts, '2026-11-09')

test('costs sort numerically, with blanks last in both directions and zero retained', () => {
  const rows = [row('blank'), row('hundred', { unit_cost_ex_gst: '100' }), row('twenty', { unit_cost_ex_gst: '20' }), row('zero', { unit_cost_ex_gst: 0 })]
  assert.deepEqual(ids(sort(rows, 'unit_cost_ex_gst')), ['zero', 'twenty', 'hundred', 'blank'])
  assert.deepEqual(ids(sort(rows, 'unit_cost_ex_gst', 'desc')), ['hundred', 'twenty', 'zero', 'blank'])
})

test('archive timestamps sort by instant, unknown dates stay last', () => {
  const rows = [row('unknown'), row('later', { archived_at: '2026-11-10T00:00:00+13:00' }), row('earlier', { archived_at: '2026-11-09T10:00:00Z' })]
  assert.deepEqual(ids(sort(rows, 'archived_at')), ['earlier', 'later', 'unknown'])
  assert.deepEqual(ids(sort(rows, 'archived_at', 'desc')), ['later', 'earlier', 'unknown'])
})

test('Yes and No usage sorts in either direction without losing false values', () => {
  const rows = [row('yes', { seen_in_sales: true }), row('no')]
  assert.deepEqual(ids(sort(rows, 'seen_in_sales')), ['no', 'yes'])
  assert.deepEqual(ids(sort(rows, 'seen_in_sales', 'desc')), ['yes', 'no'])
})

test('draft costs and effective dates use service IDs; sorting never mutates drafts or input rows', () => {
  const rows = [row('a'), row('b'), row('c')]
  const drafts = { a: { amount: '100', effectiveFrom: '2026-11-01' }, b: { amount: '20', effectiveFrom: '2026-11-11' } }
  const original = structuredClone(drafts)
  assert.deepEqual(ids(sort(rows, 'draft_unit_cost', 'asc', drafts)), ['b', 'a', 'c'])
  assert.deepEqual(ids(sort(rows, 'draft_effective_from', 'asc', drafts)), ['a', 'c', 'b'])
  assert.deepEqual(drafts, original)
  assert.deepEqual(ids(rows), ['a', 'b', 'c'])
})

test('text sorting is natural and case insensitive, ties stay stable, and off preserves the original order', () => {
  const rows = [row('a', { service_name: 'Service 10' }), row('b', { service_name: 'service 2' }), row('c', { service_name: 'SERVICE 2' })]
  assert.deepEqual(ids(sort(rows, 'service_name')), ['b', 'c', 'a'])
  assert.deepEqual(ids(sort(rows, 'service_name', 'desc')), ['a', 'b', 'c'])
  assert.deepEqual(ids(sortServiceProductCosts(rows, null, {}, '2026-11-09')), ['a', 'b', 'c'])
})
