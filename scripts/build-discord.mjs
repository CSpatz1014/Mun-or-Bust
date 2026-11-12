import {readFileSync,writeFileSync} from 'node:fs';
const root=new URL('../supabase/functions/discord-bridge/',import.meta.url);
writeFileSync(new URL('index.ts',root),readFileSync(new URL('handler.js',root),'utf8')+'\nDeno.serve(createHandler({env:Deno.env}));\n');
