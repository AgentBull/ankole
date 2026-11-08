import { expect, test } from '@playwright/test'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

test('an Applet aggregate refreshes when only a linked table changes', async ({ browser }) => {
  const viewerContext = await browser.newContext()
  const ownerContext = await browser.newContext()
  const viewer = await viewerContext.newPage()
  const owner = await ownerContext.newPage()
  try {
    await viewerContext.addCookies(state.viewer.cookies)
    await ownerContext.addCookies(state.owner.cookies)
    await owner.goto(state.base_url + pageRoute(state.report_id))
    // The owner edits the Items table only; the Orders table that the Applet queries keeps its data version.
    const setItemAmount = async (amount: number) => {
      const [item] = (
        await request<{ records: { id: string; versions: Record<string, number> }[] }>(
          owner,
          `/tables/${state.aggregate_items_table_id}/query`,
          'POST',
          { ids: [state.aggregate_item_id] }
        )
      ).records
      await request(owner, `/tables/${state.aggregate_items_table_id}/records`, 'POST', {
        updates: [
          { id: item!.id, data: { [state.aggregate_item_amount_field_id]: amount }, expected_versions: item!.versions }
        ]
      })
    }
    await setItemAmount(10)
    await viewer.goto(state.base_url + pageRoute(state.aggregate_applet_id))
    const total = viewer.frameLocator('iframe').locator('.aggregate-items-total')
    await expect(total).toHaveText('Items total 10')

    await setItemAmount(12.5)
    await expect(total).toHaveText('Items total 12.5')
  } finally {
    await viewerContext.close()
    await ownerContext.close()
  }
})
