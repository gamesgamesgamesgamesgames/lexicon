import { source } from '@/lib/source'
import { ImageResponse } from 'next/og'
import { type NextRequest } from 'next/server'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

export async function GET(request: NextRequest) {
	const slug = request.nextUrl.searchParams.get('slug')
	const slugParts = slug ? slug.split('/') : undefined
	const page = source.getPage(slugParts)

	const title = page?.data.title ?? 'The Pentaract'
	const description = page?.data.description ?? 'AT Protocol game lexicons'

	const publicDir = join(process.cwd(), 'packages/docs/public')

	const logoPng = await readFile(
		join(publicDir, 'pentaract-logo.png'),
	)
	const logoSrc = `data:image/png;base64,${logoPng.toString('base64')}`

	const [geistFont, specialEliteFont, dragonsteelFont] = await Promise.all([
		fetch(
			'https://cdn.jsdelivr.net/fontsource/fonts/geist-sans@latest/latin-600-normal.ttf',
		).then((res) => res.arrayBuffer()),
		fetch(
			'https://fonts.gstatic.com/s/specialelite/v20/XLYgIZbkc4JPUL5CVArUVL0nhnc.ttf',
		).then((res) => res.arrayBuffer()),
		readFile(join(publicDir, 'Dragonsteel-Rough.otf')),
	])

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
							{title}
						</div>

						<div
							style={{
								fontSize: 40,
								fontFamily: 'Special Elite',
								fontWeight: 400,
								color: 'rgb(161, 161, 170)',
								lineHeight: 1.4,
							}}>
							{description.length > 120
								? `${description.slice(0, 117)}...`
								: description}
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
			width: 1200,
			height: 630,
			fonts: [
				{
					name: 'Geist',
					data: geistFont,
					weight: 600,
					style: 'normal',
				},
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
