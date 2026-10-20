import { buildNodeAddon } from './node-addon'

buildNodeAddon({ release: process.argv.includes('--release') })
