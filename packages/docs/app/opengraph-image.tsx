import { ImageResponse } from 'next/og'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

export const alt = 'The Pentaract — AT Protocol game lexicons'
export const size = { width: 1200, height: 630 }
export const contentType = 'image/png'

const publicDir = join(process.cwd(), 'public')

export default async function OGImage() {
	const [logoPng, specialEliteFont, dragonsteelFont] = await Promise.all([
		readFile(join(publicDir, 'pentaract-logo.png')),
		fetch(
			'https://fonts.gstatic.com/s/specialelite/v20/XLYgIZbkc4JPUL5CVArUVL0nhnc.ttf',
		).then((res) => res.arrayBuffer()),
		readFile(join(publicDir, 'Dragonsteel-Rough.otf')),
	])

	const logoSrc = `data:image/png;base64,${logoPng.toString('base64')}`

	return new ImageResponse(
		(
			<div
				style={{
					width: '100%',
					height: '100%',
					display: 'flex',
					flexDirection: 'column',
					background: 'rgb(10, 10, 11)',
					padding: '60px 80px',
				}}>
				<div
					style={{
						display: 'flex',
						alignItems: 'center',
						gap: 60,
						flex: 1,
					}}>
					<img
						src={logoSrc}
						width={340}
						height={340}
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
								fontSize: 88,
								fontFamily: 'Dragonsteel',
								fontWeight: 400,
								color: 'rgb(250, 250, 250)',
								lineHeight: 1.1,
							}}>
							The Pentaract
						</div>

						<div
							style={{
								fontSize: 40,
								fontFamily: 'Special Elite',
								fontWeight: 400,
								color: 'rgb(161, 161, 170)',
								lineHeight: 1.4,
							}}>
							The AppView for the games.gamesgamesgamesgames.* AT Protocol lexicons
						</div>
					</div>
				</div>

				<div
					style={{
						display: 'flex',
						justifyContent: 'flex-end',
						width: '100%',
					}}>
					<div
						style={{
							fontSize: 48,
							fontFamily: 'Dragonsteel',
							fontWeight: 400,
							color: 'rgb(115, 115, 122)',
						}}>
						The Pentaract
					</div>
				</div>
			</div>
		),
		{
			...size,
			fonts: [
				{
					name: 'Special Elite',
					data: specialEliteFont,
					weight: 400,
					style: 'normal',
				},
				{
					name: 'Dragonsteel',
					data: dragonsteelFont,
					weight: 400,
					style: 'normal',
				},
			],
		},
	)
}
