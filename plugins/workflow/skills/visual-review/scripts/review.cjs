#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const schema = require('../assets/schema.js');
const resources = path.resolve(__dirname, '../assets');
const digest = b => crypto.createHash('sha256').update(b).digest('hex');
const json = p => JSON.parse(fs.readFileSync(p, 'utf8'));
function safeFile(root, relative) {
  const base = fs.realpathSync(root), p = fs.realpathSync(path.join(base, relative));
  if (!p.startsWith(base + path.sep) || !fs.statSync(p).isFile()) throw Error('Asset escapes package or is not a file');
  return p;
}
function mediaType(p) {
  return ({'.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.webp':'image/webp','.webm':'video/webm','.mp4':'video/mp4','.js':'text/javascript','.css':'text/css','.html':'text/html','.json':'application/json'})[path.extname(p)] || 'application/octet-stream';
}
function verifyMedia(p, a) {
  const bytes = fs.readFileSync(p);
  if (!bytes.length || bytes.length > 250 * 1024 * 1024) throw Error('Media exceeds 250 MB or is empty');
  const ext = path.extname(p);
  const valid = ext === '.png' ? bytes.subarray(0,8).equals(Buffer.from('89504e470d0a1a0a','hex')) :
    ['.jpg','.jpeg'].includes(ext) ? bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 :
    ext === '.webp' ? bytes.toString('ascii',0,4) === 'RIFF' && bytes.toString('ascii',8,12) === 'WEBP' :
    ext === '.mp4' ? bytes.toString('ascii',4,8) === 'ftyp' : bytes.subarray(0,4).equals(Buffer.from('1a45dfa3','hex'));
  if (!valid) throw Error(`Media signature does not match extension: ${a.path}`);
  if (ext === '.png' && (bytes.length < 24 || bytes.readUInt32BE(16) !== a.width || bytes.readUInt32BE(20) !== a.height)) throw Error(`PNG dimensions do not match: ${a.path}`);
  const hash = digest(bytes);
  if (a.sha256 && a.sha256 !== hash) throw Error(`Media digest mismatch: ${a.path}`);
  return { bytes, hash };
}
function load(manifestPath) {
  const m = schema.manifest(json(manifestPath));
  const root = path.dirname(path.resolve(manifestPath));
  for (const a of m.assets) verifyMedia(safeFile(root,a.path), a);
  return m;
}
function build(input, output, priorManifest, feedbackPath, responsesPath) {
  const m = load(input), out = path.resolve(output), source = path.dirname(path.resolve(input));
  if (fs.existsSync(out)) throw Error('Output already exists; use a new capture directory');
  const bundle = { manifest: m, viewer_version: 1 };
  if (priorManifest || feedbackPath || responsesPath) {
    if (!priorManifest || !feedbackPath || !responsesPath) throw Error('Rework requires original manifest, feedback and responses');
    const previous = load(priorManifest);
    if (previous.repository !== m.repository || previous.pr !== m.pr || previous.capture_id === m.capture_id) throw Error('Rework must be a new capture of the same PR');
    const feedback = schema.feedback(json(feedbackPath), previous);
    bundle.previous_review = {manifest: previous, feedback, responses: schema.responses(json(responsesPath), feedback, m)};
  }
  fs.mkdirSync(out, {recursive:true});
  for (const a of m.assets) {
    const {bytes,hash} = verifyMedia(safeFile(source,a.path), a);
    a.sha256 = hash;
    const target = path.join(out,a.path);
    fs.mkdirSync(path.dirname(target),{recursive:true}); fs.writeFileSync(target,bytes,{flag:'wx'});
  }
  for (const name of ['index.html','viewer.js','style.css','schema.js']) fs.copyFileSync(path.join(resources,name),path.join(out,name),fs.constants.COPYFILE_EXCL);
  fs.writeFileSync(path.join(out,'manifest.json'),JSON.stringify(m,null,2)+'\n',{flag:'wx'});
  if (bundle.previous_review) fs.writeFileSync(path.join(out,'previous-review.json'),JSON.stringify(bundle.previous_review,null,2)+'\n',{flag:'wx'});
  fs.writeFileSync(path.join(out,'package.js'),'globalThis.VISUAL_REVIEW_PACKAGE = '+JSON.stringify(bundle).replace(/</g,'\\u003c')+';\n',{flag:'wx'});
  return {capture_id:m.capture_id,package:out,coverage:m.changes.some(c=>c.status==='blocked')?'incomplete':'captured inventory',published:false};
}
function serve(root, port=0) {
  const base=fs.realpathSync(root); load(path.join(base,'manifest.json'));
  const server=http.createServer((req,res)=>{
    try {
      if (!['GET','HEAD'].includes(req.method)) {res.writeHead(405);res.end();return;}
      const raw=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
      const relative=raw==='/'?'index.html':raw.slice(1);
      if (!['index.html','viewer.js','style.css','schema.js','package.js','manifest.json','previous-review.json'].includes(relative) && !relative.startsWith('media/')) throw Error('Not found');
      const file=safeFile(base,relative), size=fs.statSync(file).size;
      const headers={'Content-Type':mediaType(file),'X-Content-Type-Options':'nosniff','Cache-Control':'no-store','Accept-Ranges':'bytes'};
      let start=0,end=size-1,code=200;
      if(req.headers.range){
        const match=/^bytes=(\d+)-(\d*)$/.exec(req.headers.range);
        if(!match){res.writeHead(416);res.end();return;}
        start=Number(match[1]);end=match[2]?Number(match[2]):end;
        if(start>end||end>=size){res.writeHead(416,{'Content-Range':`bytes */${size}`});res.end();return;}
        code=206;headers['Content-Range']=`bytes ${start}-${end}/${size}`;
      }
      headers['Content-Length']=end-start+1;res.writeHead(code,headers);
      if(req.method==='HEAD')res.end();else fs.createReadStream(file,{start,end}).pipe(res);
    } catch {res.writeHead(404);res.end('Not found');}
  });
  server.listen(Number(port),'127.0.0.1',()=>console.log(`Visual review: http://127.0.0.1:${server.address().port}`));
  return server;
}
if(require.main===module){
  try {
    const [cmd,...args]=process.argv.slice(2);
    if(cmd==='build'&&[2,5].includes(args.length)) console.log(JSON.stringify(build(...args),null,2));
    else if(cmd==='validate'&&args.length===1) {const m=load(args[0]);console.log(`Valid capture ${m.capture_id}: ${m.changes.length} changes, ${m.assets.length} assets`);}
    else if(cmd==='feedback'&&args.length===2) console.log(JSON.stringify(schema.feedback(json(args[1]),load(args[0])),null,2));
    else if(cmd==='serve'&&args.length>=1&&args.length<=2) serve(...args);
    else if(cmd==='--help') console.log('review.cjs build <manifest.json> <new-output-dir> [<original-manifest.json> <feedback.json> <responses.json>]\nreview.cjs validate <manifest.json>\nreview.cjs feedback <original-manifest.json> <feedback.json>\nreview.cjs serve <package-dir> [port=0]');
    else throw Error('Invalid arguments; use --help');
  }catch(e){console.error(e.message);process.exitCode=1;}
}
module.exports={build,load,serve,verifyMedia,safeFile};
