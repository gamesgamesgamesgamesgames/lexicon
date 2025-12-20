#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'fs'
import { fileURLToPath } from 'url'
import { dirname, join } from 'path'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

const indexPath = join(__dirname, '../src/index.ts')
const content = readFileSync(indexPath, 'utf-8')

// Check if imports are already present
if (content.includes("from '@atproto/api")) {
  console.log('✓ Imports already present')
  process.exit(0)
}

// Find the last import statement
const lines = content.split('\n')
let lastImportIndex = -1

for (let i = 0; i < lines.length; i++) {
  if (lines[i].startsWith('import ')) {
    lastImportIndex = i
  }
}

// Add the new imports after the last import
const newImports = [
  "import * as ComAtprotoRepoListRecords from '@atproto/api/dist/client/types/com/atproto/repo/listRecords.js'",
  "import * as ComAtprotoRepoGetRecord from '@atproto/api/dist/client/types/com/atproto/repo/getRecord.js'",
  "import * as ComAtprotoRepoCreateRecord from '@atproto/api/dist/client/types/com/atproto/repo/createRecord.js'",
  "import * as ComAtprotoRepoPutRecord from '@atproto/api/dist/client/types/com/atproto/repo/putRecord.js'",
  "import * as ComAtprotoRepoDeleteRecord from '@atproto/api/dist/client/types/com/atproto/repo/deleteRecord.js'",
]

lines.splice(lastImportIndex + 1, 0, ...newImports)

writeFileSync(indexPath, lines.join('\n'))
console.log('✓ Added ATProto imports to index.ts')
