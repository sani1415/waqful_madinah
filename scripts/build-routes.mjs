import { copyFileSync, mkdirSync } from 'fs';
import { join } from 'path';

const root = process.cwd();
const routes = [
  ['teacher.html', 'teacher'],
  ['student.html', 'student'],
];

for (const [source, routeDir] of routes) {
  const dir = join(root, routeDir);
  mkdirSync(dir, { recursive: true });
  copyFileSync(join(root, source), join(dir, 'index.html'));
  console.log(`[build-routes] wrote ${routeDir}/index.html from ${source}`);
}
