import { ImageResponse } from 'next/og'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

export const alt = 'The Pentaract — AT Protocol game lexicons'
export const size = { width: 1200, height: 630 }
export const contentType = 'image/png'

export default async function OGImage() {
	const logoPng = await readFile(
		join(process.cwd(), 'public/pentaract-logo.png'),
	)
	const logoSrc = `data:image/png;base64,${logoPng.toString('base64')}`

	const geistFont = await fetch(
		'https://cdn.jsdelivr.net/fontsource/fonts/geist-sans@latest/latin-600-normal.ttf',
	).then((res) => res.arrayBuffer())

	return new ImageResponse(
		(
			<div
				style={{
					width: '100%',
					height: '100%',
					display: 'flex',
					alignItems: 'center',
					justifyContent: 'center',
					background: 'rgb(10, 10, 11)',
					padding: '60px 80px',
					gap: 60,
				}}>
				<img
					src={logoSrc}
					width={280}
					height={280}
				/>

				<div
					style={{
						display: 'flex',
						flexDirection: 'column',
						gap: 16,
						flex: 1,
					}}>
					<div
						style={{
							fontSize: 64,
							fontFamily: 'Geist',
							fontWeight: 600,
							color: 'rgb(250, 250, 250)',
							lineHeight: 1.1,
						}}>
						The Pentaract
					</div>

					<div
						style={{
							fontSize: 28,
							fontFamily: 'Geist',
							fontWeight: 600,
							color: 'rgb(161, 161, 170)',
							lineHeight: 1.4,
						}}>
						The AppView for the games.gamesgamesgamesgames.* AT Protocol lexicons
					</div>
				</div>
			</div>
		),
		{
			...size,
			fonts: [
				{
					name: 'Geist',
					data: geistFont,
					weight: 600,
					style: 'normal',
				},
			],
		},
	)
}
