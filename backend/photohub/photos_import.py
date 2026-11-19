JXA = r"""
ObjC.import('Foundation');
function run(argv) {
  const P = Application('Photos');
  const job = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
  const found = P.albums.whose({name: job.album})();
  if (!found.length) throw new Error('album not found: ' + job.album);
  const items = P.import(job.paths.map(p => Path(p)), {into: found[0], skipCheckDuplicates: true});
  const ids = items.map(i => i.id());
  if (job.extraAlbum && job.extraPaths.length) {
    const extra = P.albums.whose({name: job.extraAlbum})();
    if (!extra.length) throw new Error('album not found: ' + job.extraAlbum);
    const names = job.extraPaths.map(p => p.split('/').pop().toLowerCase());
    const picked = items.filter(i => names.indexOf(i.filename().toLowerCase()) >= 0);
    if (picked.length) P.add(picked, {to: extra[0]});
  }
  return JSON.stringify(ids);
}
"""
