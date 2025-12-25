// Module imports
import '@atcute/atproto'
import '@atcute/bluesky'

import { fileURLToPath } from 'url'
import { dirname, resolve } from 'path'

import { Client, CredentialManager, ok } from '@atcute/client'
import { TID } from '@atproto/common'

// Constants
const __dirname = dirname(fileURLToPath(import.meta.url))

// const {
// 	APP_PASSWORD,
// 	HANDLE,
// 	TARGET_REPO_DID,
// } = process.env

const APP_PASSWORD = 'h3ty-u6jj-2ogs-vuqi'
const HANDLE = 'gamesgamesgamesgames.games'

const credentialManager = new CredentialManager({
	service: 'https://bsky.social',
})
const client = new Client({ handler: credentialManager })

await credentialManager.login({
	identifier: HANDLE,
	password: APP_PASSWORD,
})

// Get a list of existing records
const { records } = await ok(
	client.get('com.atproto.repo.listRecords', {
		params: {
			repo: credentialManager.session!.did,
			collection: 'com.atproto.lexicon.schema',
		},
	}),
)

// Map existing lexicons so we can match rkeys
if (records.length) {
	console.log(records)
}

const gameLexiconFile = Bun.file(resolve(__dirname, '..', 'src', 'game.json'))
const gameLexiconJSON = await gameLexiconFile.json()

await client.post('com.atproto.repo.putRecord', {
	input: {
		repo: credentialManager.session!.did,
		collection: 'com.atproto.lexicon.schema',
		rkey: TID.nextStr(),
		record: gameLexiconJSON,
		validate: true,
	},
})
