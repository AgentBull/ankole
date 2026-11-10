import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { ApprovalCard, type ApprovalCardProps } from '../src/components/approval-card'

const review = {
  approveLabel: 'Accept',
  rejectLabel: 'Decline',
  onDecision: () => {},
  reasonField: (
    <label>
      Reason <textarea />
    </label>
  )
}

test('ApprovalCard gives an assigned pending reviewer decision controls and a caller-owned reason field', () => {
  const html = renderToStaticMarkup(
    <ApprovalCard
      title="Review proposal"
      summary="Update the working plan"
      status="pending"
      statusLabel="Awaiting review"
      details={<a href="/evidence">Evidence</a>}
      review={review}
    />
  )

  expect(html).toContain('role="status"')
  expect(html).toContain('Awaiting review')
  expect(html).toContain('href="/evidence"')
  expect(html).toContain('<textarea')
  expect(html).toContain('>Accept</button>')
  expect(html).toContain('>Decline</button>')
})

test('ApprovalCard disables a review in progress and hides review controls on receipts and read-only cards', () => {
  const render = (status: ApprovalCardProps['status'], controls?: ApprovalCardProps['review']) =>
    renderToStaticMarkup(
      <ApprovalCard
        title="Review proposal"
        summary="Update the working plan"
        status={status}
        statusLabel={status}
        review={controls}
      />
    )

  const submitting = render('pending', { ...review, submitting: true, submittingLabel: 'Saving review' })
  expect(submitting).toMatch(/<fieldset\b[^>]*\bdisabled=""/)
  expect(submitting).toContain('Saving review')

  for (const html of [render('approved', review), render('rejected', review), render('pending')]) {
    expect(html).not.toContain('<button')
    expect(html).not.toContain('<textarea')
  }
})
