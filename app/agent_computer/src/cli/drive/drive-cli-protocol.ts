import { z } from 'zod'

// A folder is often written with a trailing slash, as in reports/ or a bare /.
const withoutTrailingSlashes = (path: string) => path.replace(/\/+$/u, '')
const RawDrivePath = z.string().trim().min(1).max(1024)
const DrivePath = RawDrivePath.transform(withoutTrailingSlashes).pipe(z.string().min(1))
const LocalPath = z.string().trim().min(1).max(4096)

const ListDriveCommand = z.object({
  operation: z.literal('list'),
  prefix: z.string().trim().max(1024).transform(withoutTrailingSlashes),
  limit: z.number().int().positive().max(1000).optional(),
  after: z.string().min(1).max(1024).optional()
})

const GetDriveCommand = z.object({
  operation: z.literal('get'),
  path: DrivePath,
  pod: z.boolean().optional(),
  output: LocalPath.optional(),
  cwd: LocalPath
})

const PutDriveCommand = z.object({
  operation: z.literal('put'),
  local_path: LocalPath,
  // The bridge reads a trailing slash as "into this folder", as cp does.
  path: RawDrivePath,
  cwd: LocalPath
})

const RemoveDriveCommand = z.object({
  operation: z.literal('rm'),
  path: DrivePath
})

export const DriveCLICommand = z.discriminatedUnion('operation', [
  ListDriveCommand,
  GetDriveCommand,
  PutDriveCommand,
  RemoveDriveCommand
])

export type DriveCLICommand = z.output<typeof DriveCLICommand>
