import { useId, type ReactNode } from 'react'
import { Badge } from './badge'
import { Button } from './button'
import { Card, CardAction, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from './card'
import { FieldSet } from './field'

export type ApprovalDecision = 'approved' | 'rejected'

export type ApprovalCardProps = {
  title: string
  summary: ReactNode
  status: 'pending' | ApprovalDecision
  statusLabel: string
  details?: ReactNode
  /** Provide review controls when the viewer can decide. The caller owns submission and any reason field. */
  review?: {
    approveLabel: string
    rejectLabel: string
    onDecision: (decision: ApprovalDecision) => void
    reasonField?: ReactNode
    submitting?: boolean
    submittingLabel?: string
  }
  className?: string
}

const statusVariant = {
  pending: 'warning',
  approved: 'success',
  rejected: 'destructive'
} as const

export function ApprovalCard({ title, summary, status, statusLabel, details, review, className }: ApprovalCardProps) {
  const titleId = useId()
  return (
    <Card size="sm" className={className} role="group" aria-labelledby={titleId}>
      <CardHeader>
        <CardTitle id={titleId} className="min-w-0 wrap-anywhere">
          {title}
        </CardTitle>
        <CardDescription className="min-w-0 wrap-anywhere">{summary}</CardDescription>
        <CardAction>
          <Badge variant={statusVariant[status]} role="status">
            {statusLabel}
          </Badge>
        </CardAction>
      </CardHeader>
      {details != null && <CardContent className="min-w-0 wrap-anywhere">{details}</CardContent>}
      {status === 'pending' && review && (
        <FieldSet disabled={review.submitting} className="min-w-0 gap-3">
          {review.reasonField != null && <CardContent>{review.reasonField}</CardContent>}
          <CardFooter className="flex-wrap gap-2">
            <Button type="button" size="sm" onClick={() => review.onDecision('approved')}>
              {review.approveLabel}
            </Button>
            <Button type="button" size="sm" variant="outline" onClick={() => review.onDecision('rejected')}>
              {review.rejectLabel}
            </Button>
            {review.submitting && review.submittingLabel && (
              <span role="status" className="text-xs text-muted-foreground">
                {review.submittingLabel}
              </span>
            )}
          </CardFooter>
        </FieldSet>
      )}
    </Card>
  )
}
