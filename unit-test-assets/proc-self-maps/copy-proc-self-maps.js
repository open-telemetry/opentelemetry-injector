#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const sourcePath = '/proc/self/maps';
const outDir = '/workspace';
const destPath = path.join(outDir, 'proc-self-maps');

try {
  const data = fs.readFileSync(sourcePath);
  fs.writeFileSync(destPath, data);
  console.log(`successfully copied ${sourcePath} to ${destPath}`);
} catch (error) {
  console.error(`error copying file: ${error.message}`);
  process.exit(1);
}
