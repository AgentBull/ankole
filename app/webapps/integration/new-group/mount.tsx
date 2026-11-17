import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { loadLocale } from '../../common/i18n'
import { AppProviders, createQueryClient } from '../../common/providers'
import type { ConversationDetail } from '../../pod/api'
import { NewGroupDialog } from '../../pod/chat/new-group-dialog'
import '@ankole/uikit/styles.css'

const detail: ConversationDetail = {
  activities: [],
  pendingQueues: [],
  pendingInteractions: [],
  linkedRuns: [],
  artifacts: { pageIDs: [], attachments: [] },
  editableInputs: [],
  removedMessageIDs: [],
  olderMessagesBeforeSeq: null,
  messageRange: { firstSeq: 1, lastSeq: 1 },
  messages: [],
  conversation: {
    accessScope: 'participants',
    canDelete: true,
    canManage: true,
    roomMode: 'dm',
    conversationKind: 'colleague_dm',
    titleCustomized: false,
    createdBy: 'person',
    lastMessageSeq: 1,
    lastNotifiableSeq: 1,
    rowStatus: 'idle',
    viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq: 1 },
    agents: [],
    participants: [
      { uid: 'person', displayName: 'Person', active: true, type: 'human', role: 'owner', mayIntervene: false },
      { uid: 'colleague', displayName: 'Colleague', active: true, type: 'human', mayIntervene: false }
    ],
    pageID: null,
    id: '00112233-4455-6677-8899-aabbccddeeff',
    title: 'Colleague',
    agent: { uid: 'colleague', displayName: 'Colleague', active: true },
    lastActivityAt: '2026-11-17T00:00:00Z'
  }
}

function NewGroupFixture() {
  const [open, setOpen] = useState(true)
  return <NewGroupDialog detail={detail} open={open} onOpenChange={setOpen} />
}

await loadLocale('en-US')
const client = createQueryClient()
const router = createRouter({ routeTree: createRootRoute({ component: NewGroupFixture }) })
createRoot(document.getElementById('root')!).render(
  <AppProviders queryClient={client}>
    <RouterProvider router={router} />
  </AppProviders>
)
