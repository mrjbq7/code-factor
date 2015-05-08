! Copyright (C) 2015 Doug Coleman.
! See http://factorcode.org/license.txt for BSD license.
USING: accessors arrays calendar checksums checksums.sha
combinators combinators.smart compression.zlib constructors io
io.binary io.directories.search io.encodings.binary
io.encodings.string io.encodings.utf8 io.files io.files.info
io.pathnames io.streams.byte-array kernel math math.parser
namespaces prettyprint sequences sequences.generalizations
splitting tools.hexdump grouping ;
IN: git

: find-git-directory ( path -- path' )
    [ ".git" tail? ] find-up-to-root ; inline

ERROR: not-a-git-directory path ;

: current-git-directory ( -- path )
    current-directory get find-git-directory [
        current-directory get not-a-git-directory
    ] unless* ;

: make-git-path ( str -- path )
    current-git-directory prepend-path ;

: make-refs-path ( str -- path )
    [ "refs/" make-git-path ] dip append-path ;

: make-object-path ( str -- path )
    [ "objects/" make-git-path ] dip 2 cut append-path append-path ;

: git-utf8-contents ( str -- contents )
    make-git-path utf8 file-contents ;

: git-binary-contents ( str -- contents )
    make-git-path binary file-contents ;

: list-refs ( -- seq )
    current-git-directory "refs/" append-path f recursive-directory-files ;

: ref-contents ( str -- contents )
    make-refs-path utf8 file-contents ;

: git-head-contents ( -- contents )
    "HEAD" git-utf8-contents ;

: git-stash-contents ( -- contents )
    "stash" git-utf8-contents ;

: git-object-contents ( hash -- contents )
    make-object-path binary file-contents uncompress ;

TUPLE: index-entry ctime mtime data sha1 flags name ;
CONSTRUCTOR: <index-entry> index-entry ( ctime mtime data sha1 flags name -- obj ) ;

: read-index-entry-v2 ( -- seq )
    4 read be> 4 read be> 2array
    4 read be> 4 read be> 2array
    4 read 4 read 4 read 4 read 4 read 4 read 6 narray
    20 read hex-string
    2 read { 0 } read-until drop [ utf8 decode ] [ length ] bi
    7 + 8 mod dup zero? [ 8 swap - ] unless read drop
    <index-entry> ;

TUPLE: git-index magic version entries checksum ;
CONSTRUCTOR: <git-index> git-index ( magic version entries checksum -- obj ) ;

ERROR: unhandled-git-version n ;
ERROR: unhandled-git-index-trailing-bytes bytes ;

: git-index-contents ( -- bytes )
    "index" make-git-path binary [
        4 read utf8 decode
        4 read be>
        4 read be> over {
            { 2 [ [ read-index-entry-v2 ] replicate ] }
            [ unhandled-git-version ]
        } case
        20 read hex-string
        <git-index>
    ] with-file-reader ;

: make-git-object ( str -- bytes )
    [
        [ "blob " ] dip [ length number>string "\0" ] [ ] bi
    ] B{ } append-outputs-as ;

: path>git-object ( path -- bytes )
    binary file-contents make-git-object sha1 checksum-bytes ;

: git-hash-object ( str -- hash )
    make-git-object sha1 checksum-bytes ;

: changed-index-by-sha1 ( -- seq )
    git-index-contents entries>>
    [ [ sha1>> ] [ name>> path>git-object hex-string ] bi = not ] filter ;

: changed-index-by-mtime ( -- seq )
    git-index-contents entries>>
    [
        [ mtime>> first ]
        [ name>> file-info modified>> timestamp>unix-time >integer ] bi = not
    ] filter ;

TUPLE: commit tree parent author committer comment ;
CONSTRUCTOR: <commit> commit ( tree parent author committer -- obj ) ;

ERROR: unknown-commit-line line name ;

ERROR: string-expected got expected ;

: expect-string ( string expected -- )
    2dup = [ 2drop ] [ string-expected ] if ;

: parse-commit ( bytes -- commit )
    [ commit new ] dip utf8 [
        " " read-until drop "tree" expect-string "\r\n" read-until drop >>tree
        " " read-until drop "parent" expect-string "\r\n" read-until drop >>parent
        " " read-until drop "author" expect-string "\r\n" read-until drop >>author
        " " read-until drop "committer" expect-string "\r\n" read-until drop >>committer
        "\r\n" read-until 2drop
        contents >>comment
    ] with-byte-reader ;

ERROR: unknown-git-object string ;

: git-read-object ( sha -- obj )
    git-object-contents utf8 [
        { 0 } read-until 0 = drop " " split1 string>number read swap {
            { "blob" [ ] }
            { "commit" [ parse-commit ] }
            { "tree" [ ] }
            [ unknown-git-object ]
        } case
    ] with-byte-reader ;

: make-idx-path ( sha -- path )
    "objects/pack/pack-" ".idx" surround make-git-path ;

: make-pack-path ( sha -- path )
    "objects/pack/pack-" ".pack" surround make-git-path ;

ERROR: idx-v1-unsupported ;

TUPLE: idx version table triples packfile-sha1 idx-sha1 ;
CONSTRUCTOR: <idx> idx ( version table triples packfile-sha1 idx-sha1 -- obj ) ;
! sha1, crc32, offset

: parse-idx-v2 ( -- idx )
    4 read be>
    256 4 * read 4 group [ be> ] map
    dup last
    [ [ 20 read ] replicate ]
    [ [ 4 read ] replicate ]
    [ [ 4 read be> ] replicate ] tri 3array flip
    20 read
    20 read <idx> ;

: parse-idx ( path -- idx )
    binary [
        4 read be> {
            { 0xff744f63 [ parse-idx-v2 ] }
            [ idx-v1-unsupported ]
        } case
    ] with-file-reader ;

: parse-pack ( path -- pack )
    binary [
        4 read >string
        4 read be>
        4 read be> 3array
    ] with-file-reader ;

: git-read-idx ( sha -- obj )
    make-idx-path parse-idx ;

: git-read-pack ( sha -- obj )
    make-pack-path parse-pack ;