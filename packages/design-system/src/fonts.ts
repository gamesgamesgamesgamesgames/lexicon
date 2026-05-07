import { Geist, Geist_Mono } from "next/font/google";
import localFont from "next/font/local";

export const geistSans = Geist({
	subsets: ["latin"],
	variable: "--font-geist-sans",
	display: "swap",
});

export const geistMono = Geist_Mono({
	subsets: ["latin"],
	variable: "--font-geist-mono",
	display: "swap",
});

export const dragonsteel = localFont({
	src: [
		{
			path: "./fonts/Dragonsteel-Regular.woff2",
			weight: "400",
			style: "normal",
		},
		{ path: "./fonts/Dragonsteel-Rough.woff2", weight: "400", style: "italic" },
	],
	variable: "--font-dragonsteel",
	display: "swap",
});

export const fontVariables = `${geistSans.variable} ${geistMono.variable} ${dragonsteel.variable}`;
