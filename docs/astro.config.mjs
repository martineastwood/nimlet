// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeBlack from 'starlight-theme-black';

export default defineConfig({
	site: 'https://nimlet.niminal.dev',
	integrations: [
		starlight({
			title: 'nimlet',
			description: 'A local coding agent for your repository. A native binary with fast startup, low memory, and idle CPU until it works.',
			favicon: '/favicon.ico',
			head: [
				{ tag: 'link', attrs: { rel: 'icon', href: '/favicon.ico', sizes: '48x48' } },
				{ tag: 'link', attrs: { rel: 'icon', type: 'image/png', sizes: '32x32', href: '/favicon-32x32.png' } },
				{ tag: 'link', attrs: { rel: 'icon', type: 'image/png', sizes: '16x16', href: '/favicon-16x16.png' } },
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', sizes: '180x180', href: '/apple-touch-icon.png' } },
			],
			customCss: ['./src/styles/sidebar.css', './src/styles/landing.css'],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/martineastwood/nimlet' }],
			sidebar: [
				{ label: 'Overview', slug: 'index' },
				{ label: 'Quickstart', slug: 'guides/quickstart' },
				{ label: 'Configuration', slug: 'guides/configuration' },
				{ label: 'Interactive TUI', slug: 'guides/interactive-tui' },
				{ label: 'Plan and act mode', slug: 'guides/plan-and-act' },
				{ label: 'Permissions', slug: 'guides/permissions' },
				{ label: 'Security', slug: 'guides/security' },
				{ label: 'Sessions', slug: 'guides/sessions' },
				{ label: 'Context and compaction', slug: 'guides/context-and-compaction' },
				{ label: 'Models and providers', slug: 'guides/models-and-providers' },
				{ label: 'Instructions', slug: 'guides/instructions' },
				{ label: 'Skills', slug: 'guides/skills' },
				{ label: 'Prompt templates', slug: 'guides/prompt-templates' },
				{ label: 'External tools', slug: 'guides/external-tools' },
				{ label: 'Extensions and hooks', slug: 'guides/extensions-and-hooks' },
				{ label: 'Built-in tools', slug: 'reference/tools' },
				{ label: 'Commands and shortcuts', slug: 'reference/commands' },
				{ label: 'Keyboard shortcuts', slug: 'reference/keybindings' },
				{ label: 'JSON mode', slug: 'reference/json-mode' },
				{ label: 'RPC mode', slug: 'reference/rpc-mode' },
				{ label: 'Files and directories', slug: 'reference/files-and-directories' },
				{ label: 'Architecture', slug: 'reference/architecture' },
			],
			plugins: [
				starlightThemeBlack({
					navLinks: [{ label: 'Niminal', link: 'https://niminal.dev' }],
					docs: { showMarkdownActions: false },
				}),
			],
		}),
	],
});
