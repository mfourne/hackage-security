# Hackage Security

This is a library for Hackage security based on [TUF, The Update
Framework][TUF].

## Comparison with TUF

In this section we highlight some of the differences in the specifics of the
implementation; generally we try to follow the TUF model as closely as
possible.

This section is not (currently) intended to be complete.

### Targets

In the current proposal we do not yet implement author signing, but when we do
implement author signing we want to have a smooth transition, and moreover we
want to be able to have a mixture of packages, some of which are author signed
and some of which are not. That is, package authors must be able to opt-in to
author signing (or not).

#### Unsigned packages

##### Package specific metadata

Version 1.0 of package `Foo` will be stored in `/Foo/1.0`. This directory will
contain a single metadata file `/Foo/1.0/targets.json` containing the hash and
size of the package tarball:

``` javascript
{ "signed" : {
     "_type"   : "Targets"
   , "version" : VERSION
   , "expires" : never
   , "targets" : {
         "Foo-1.0.tar.gz" : FILEINFO
       }
   }
, "signatures" : []
}
```

Note that expiry dates are relevant only for information that we expect to
change over time (such as the snapshot). Since packages are immutable, they
cannot expire. (Additionally, there is no point adding an expiry date to files
that are protected only the snapshot key, as the snapshot _itself_ will expire).

There is no point listing the file info of the `.cabal` files here: `.cabal`
files are listed by value in the index tarball, and are therefore already
protected by the snapshot key (but see author signing, below).

##### Delegation

We then have a top-level `targets.json` that contains the required delegation
information:

``` javascript
{ "signed" : {
      "_type"       : Targets
    , "version"     : VERSION
    , "expires"     : never
    , "targets"     : []
    , "delegations" : {
          "keys"  : []
        , "roles" : [
               { "name"      : "*/*/targets.json"
               , "keyids"    : []
               , "threshold" : 0
               , "path"      : "*/*/*"
               }
             ]
       }
    }
, "signatures" : /* target keys */
}
```

This file itself is signed by the target keys (kept offline by the Hackage
admins).  

<blockquote>
<i>Extension to TUF spec.</i>
This uses an extension to the TUF spec where we can use wildcards in names as
well as in paths. This means that we list a <b>single</b> path with a
<b>single</b> replacement name. (Alternatively, we could have a list of pairs of
paths and names.)
</blockquote>

New unsigned packages, as well as new versions of existing unsigned packages,
can be uploaded to Hackage without any intervention from the Hackage admins (the
offline target keys are not required).

##### Security

This setup is sufficient to allow for untrusted mirrors: since they do not  have
access to the snapshot key, they (or a man-in-the-middle) cannot change which
packages are visible or change the packages themselves.

However, since the snapshot key is stored on the server, if the server itself is
compromised almost all security guarantees are void.

#### Signed packages

(We sketch the design here only, we do not actually intend to implement this yet
in phase 1 of the project.)

##### Package specific metadata

As for unsigned packages, we keep metadata specific for each package version.
Unlike for unsigned packages, however, we store two files: one that can be
signed by the package author, and one that can be signed by the Hackage
trustees, which can upload new `.cabal` file revisions but not change the
package contents.

Thus we have `targets.json`, containing precisely two entries:

``` javascript
{ "signed" : {
     "_type"   : "Targets"
   , "version" : VERSION
   , "expires" : never
   , "targets" : {
         "Foo-1.0.tar.gz" : FILEINFO
       , "Foo-1.0.cabal"  : FILEINFO
       }
   }
, "signatures" : /* signatures from package authors */
}
```

and `revisions.json`:

``` javascript
{ "signed" : {
     "_type"   : "Targets"
   , "version" : VERSION
   , "expires" : never
   , "targets" : {
       , "Foo-1.0-rev1.cabal" : FILEINFO
       , "Foo-1.0-rev2.cabal" : FILEINFO
       , ...
       }
   }
, "signatures" : /* signatures from package authors or Hackage trustees */
}
```

Unlike for unsigned packages, listing the file info for the `.cabal` file is
useful for signed packages: although the `.cabal` files are listed by value in
the index  tarball, the index is only signed by the snapshot key. We may want to
additionally check that the `.cabal` are properly author signed too.

##### Delegation

Delegation for signed packages is a bit more complicated. We extend the
top-level targets file to

``` javascript
{ "signed" : {
      "_type"       : Targets
    , "version"     : VERSION
    , "expires"     : EXPIRES
    , "targets"     : []
    , "delegations" : {
          "keys"  : /* Hackage trustee keys */
        , "roles" : [
               { "name"      : "*/*/targets.json"
               , "keyids"    : []
               , "threshold" : 0
               , "path"      : "*/*/*"
               }
             // Delegation for package Bar
             , { "name"      : "Bar/targets.json"
               , "keyids"    : <top-level target keys>
               , "threshold" : THRESHOLD
               , "path"      : "Bar/*/*"
               }
             , { "name"      : "Bar/*/revisions.json"
               , "keyids"    : <Hackage trustee key IDs>
               , "threshold" : THRESHOLD
               , "path"      : "Bar/*/*.cabal"
               }
             // Delegation for package Baz
             , { "name"      : "Baz/targets.json"
               , "keyids"    : <top-level target keys>
               , "threshold" : THRESHOLD
               , "path"      : "Baz/*/*"
               }
             , { "name"      : "Baz/*/revisions.json"
               , "keyids"    : <Hackage trustee key IDs>
               , "threshold" : THRESHOLD
               , "path"      : "Baz/*/*.cabal"
               }
             // .. delegation for other signed packages ..
             ]
        }
    }
, "signatures" : /* target keys */
}
```

Since this lists all signed packages, we must list an expiry date here so that
attackers cannot mount freeze attacks (although this is somewhat less of an
issue here as freezing this list would make en entire new package, rather than
a new package version, invisible).

This says that the delegation information for package `Bar-`_x.y_ is found in
`/Bar/targets.json` as well as `/Bar/`_x.y_`/revisions.json`, where the latter
can only contain information about the `.cabal` files, not the package itself.
Note that these rules overlap with the rule for unsigned packages, and so we
need a priority scheme between rules. The TUF specification leaves this quite
open; in our case, we can implement a very simple rule: more specific rules
(rules with fewer wildcards) take precedence over less specific rules.

This &ldquo;middle level&rdquo; targets file `/Bar/targets.json` introduces the
author keys and contains further delegation information:

``` javascript
{ "signed" : {
      "_type"       : "Targets"
    , "version"     : VERSION
    , "expires"     : never
    , "targets"     : {}
    , "delegations" : {
          "keys"  : /* package maintainer keys */
        , "roles" : [
              { "name"      : "*/targets.json"
              , "keyids"    : /* package maintainer key IDs */
              , "threshold" : THRESHOLD
              , "path"      : "*/*"
              }
            , { "name"      : "*/revisions.json"
              , "keyids"    : /* package maintainer key IDs */
              , "threshold" : THRESHOLD
              , "path"      : "*/*.cabal"
              }
            ]
    }
, "signatures" : /* signatures from top-level target keys */
}
```

Some notes:

1. When a new signed package is introduced, the Hackage admins need to create
   and sign a new `targets.json` that lists the package author keys and
   appropriate delegation information, as well as add corresponding entries to
   the top-level delegation file. However, once this is done, the Hackage admins
   do not need to be involved when package authors wish to upload new versions.

2. When package authors upload a new version, they need to sign only a single
   file that contains the information about that particular version.

3. Both package authors (through the package-specific &ldquo;middle level&rdquo;
   delegation information) and Hackage trustees (through the top-level
   delegation information) can sign `.cabal` file revisions, but only authors
   can sign the packages themselves.

4. Hackage trustees are listed only in the top-level delegation information, so
   when the set of trustees changes we only need to modify one file (as opposed
   to each middle-level package delegation information).

5. For signed packages that do not want to allow Hackage trustees to sign
   `.cabal` file revisions we can just omit the corresponding entry from the
   top-level delegations file.

##### Transition packages from `unsigned` to `signed`

When a package that previously did not opt-in to author signing now wants
author-signing, we just need to add the appropriate entries to the top-level
delegation file and set up the appropriate middle-level delegation information.

##### Security

When the snapshot key is compromised, attackers still do not have access to
package author keys, which are strictly kept offline. However, they can still
mount freeze attacks on packages versions, because there is no file (which is
signed with offline key) listing which versions are available.

We could increase security here by changing the middle-level `targets.json` to
remove the wildcard rule, list all versions explicitly, and change the top-level
delegation information to say that the middle-level file should be signed by
the package authors instead.

Note that we do not use a wildcard for signed packages in the top-level
`targets.json` for a similar reason: by listing all packages that we expect to
be signed explicitly, we have a list of signed packages which is signed by
offline keys (in this case, the target keys).

### Snapshot

#### Interaction with the index tarball

According to the official specification we should have a file `snapshot.json`,
signed with the snapshot key, which lists the hashes of _all_ metadata files in
the repo. In Hackage however we have the index tarball, which _contains_ most of
the metadata files in the repo (that is, it contains all the `.cabal` files, but
it also contains all the `targets.json` files). The only thing that is missing
from the index tarball, compared to the `snapshot.json` file from the TUF spec,
is the version, expiry time, and signatures. Therefore our `snapshot.json` looks
like

``` javascript
{ "signed" : {
      "_type"   : "Snapshot"
    , "version" : VERSION
    , "expires" : EXPIRES
    , "meta"    : {
           "root.json"    : FILEINFO
         , "mirrors.json" : FILEINFO
         , "index.tar"    : FILEINFO
         , "index.tar.gz" : FILEINFO
        }
    }
, "signatures" : /* signatures from snapshot key */
}
```

Then the combination of `snapshot.json` together with the index tarball is
a strict superset of the information in TUF's `snapshot.json` (instead of
containing the hashes of the metadata in the repo, it contains the actual
metadata themselves).

We list the file info of the root and mirrors metadata explicitly, rather than
recording it in the index tarball, so that we can check them for updates during
the update process  (section 5.1, &ldquo;The Client Application&rdquo;, of the
TUF spec) without downloading the entire index tarball.

### Out-of-tarball targets

All versions of all packages are listed, along with their full `.cabal` file, in
the Hackage index. This is useful because the constraint solver needs most of
this information anyway. However, when we add additional kinds of targets we may
not wish to add these to the index: people who are not interested in these new
targets should not, or only minimally, be affected. In particular, new releases
of these new kinds of targets should not result in a linear increase in what
clients who are not interested in these targets need to download.

To support these out-of-tarball targets we can use the regular TUF setup. Since
the index does not serve as an exhaustive list of which targets (and which
target versions) are available, it becomes important to have target metadata
(`targets.json` files) that list all targets exhaustively, to avoid freeze
attacks. The file information (hash and filesize) of all these target metadata
files must, by the TUF spec, be listed in the top-level snapshot; we should thus
avoid introducing too many of them (in particular, we should avoid requiring a
new @targets.json@ for each new version of a particular kind of target).

In order to avoid name clashes OOT targets should be stored in a
location that is not a valid package name, such as `oot$`.

#### Collections

[Package collections][CabalHell1] are a new Hackage feature that's [currently in
development][ZuriHac]. We want package collections to be signed, just like
anything else.

Like packages, collections are versioned and immutable, so we have

```
oot$/collections/StackageNightly/2015.06.02/StackageNightly.collection
oot$/collections/StackageNightly/2015.06.03/StackageNightly.collection
oot$/collections/StackageNightly/...
oot$/collections/DebianJessie/...
oot$/collections/...
```

As for packages, collections should be able to opt-in for author signing (once
we support author signing), but we should also support not-author-signed
(&ldquo;unsigned&rdquo;) collections. Moreover, it should be possible for people
to create new unsigned collections without the involvement of the Hackage
admins. This rules out listing all collections explicitly in the top-level
`targets.json` (which is signed with offline target keys).

##### Unsigned collections

For unsigned collections we add a single delegation rule to the top-level
`targets.json`:

``` javascript
{ "name"      : "oot$/collections/targets.json"
, "keyids"    : /* snapshot key */
, "threshold" : 1
, "path"      : "oot$/collections/*/*/*"
}
```

The middle-level `targets.json`, signed with the snapshot role, lists delegation
rules for all available collections:

``` javascript
[ { "name"      : "StackageNightly/targets.json"
  , "keyids"    : /* snapshot key */
  , "threshold" : 1
  , "path"      : "StackageNightly/*/*"
  }
, { "name"      : "DebianJessie/targets.json"
  , "keyids"    : /* snapshot key */
  , "threshold" : 1
  , "path"      : "DebianJessie/*/*"
  }
, ...
]
```

where `StackageNightly` and `DebianJessie` are two package collection (the
[Stackage Nightly][StackageNightly] collection and the set of Haskell package
distributed with the [Debian Jessie][DebianJessie] Linux distribution).

The final per-collection targets metadata finally lists all versions:

``` javascript
{ "signed" : {
     "_type"   : "Targets"
   , "version" : VERSION
   , "expires" : /* expiry */
   , "targets" : {
         "2015.06.02/StackageNightly.collection" : FILEINFO
       , "2015.06.03/StackageNightly.collection" : FILEINFO
       , ...
       }
   }
, "signatures" : /* signed with snapshot role */
}
```

Since we cannot rely on the index to have the list of all version we must list
all versions explicitly here rather than using wildcards. Note that this means
that the snapshot will get a new entry for each new collection introduced, but
not for each new _version_ of each collection.

##### Author-signed collections

For author-signed collections we only need to make a single change. Suppose that
the `DebianJessie` collection is signed. Then we move the rule for
`DebianJessie` from `oot$/collections/targets.json` and instead list it in the
top-level `targets.json` (as for packages, introducing a signed collection
necessarily requires the involvement of the Hackage admins):

``` javascript
{ "name"      : "oot$/collections/DebianJessie/targets.json"
, "keyids"    : /* DebianJessie maintainer keys */
, "threshold" : /* threshold */
, "path"      : "oot$/collections/DebianJessie/*/*"
}
```

No other changes are required (apart from of course that
`oot$/collections/DebianJessie/targets.json` will now be signed with the
`DebianJessie` maintainer keys rather than the snapshot key). As for packages,
this requires a priority scheme for delegation rules.

Note that in a sense author-signed collections are snapshots of the server. As
such, it would be good if these collections listed the file info (hashes and
filesizes) of the packages the collection.

## Project phases and shortcuts

Phase 1 of the project will implement the basic TUF framework, but leave out
author signing; support for author signed packages (and other targets) will
added in phase 2.

### Shortcuts taken in phase 1 (aka TODOs for phase 2)

This list is currenty not exhaustive.

#### Core library

* Although the infrastructure is in place for [target metadata][Targetshs],
  including typed data types representing [pattern matches and
  replacements][Patternshs], we have not yet actually implementing target
  delegation proper. We don't need to: we only support one kind of target
  (not-author-signed packages), and we know statically where the target
  information for packages can be found (in `/package/version/targets.json`).
  This is currently hardcoded.  

  Once we have author signing we need a proper implementation of delegation,
  including a priority scheme between rules. This will also involve lazily
  downloading additional target metadata.

* Out-of-tarballs targets are not yet implemented. The main difficulty here is
  that they require a proper implementation of delegation; once that is done
  (required anyway for author signing) support for OOT targets should be
  straightforward.

#### Integration in `cabal-install`

* The cabal integration uses the `hackage-security` library to check for updates
  (that is, update the local copy of the index) and to download packages
  (verifying the downloaded file against the file info that was recorded in
  the package metadata, which itself is stored in the index). However, it does
  not use the library to get a list of available packages, nor to access
  `.cabal` files.

  Once we have author signing however we may want to do additional checks:

  * We should look at the top-level `targets.json` file (in addition to the
    index) to figure out which packages are available. (The top-level targets
    file, signed by offline keys, will enumerate all author-signed packages.)

  * If we do allow package authors to sign list of package versions (as detailed
    above) we should use these &ldquo;middle level&rdquo; target files to figure
    out which versions are available for these packages.

  * We might want to verify the `.cabal` files to make sure that they match the
    file info listed in the now author-signed metadata.

  Therefore `cabal-install` should be modified to go through the
  `hackage-security`  library get the list of available packages, package
  versions, and to access the actual `.cabal` files.

## Open questions / TODOs

* The set of maintainers of a package can change over time, and can even change
  so much that the old maintainers of a package are no longer maintainters.
  But we would still like to be able to install and verify old packages. How
  do we deal with this?

* In the spec as defined we list each revision of a cabal file separately
  (`Foo-1.0-rev1.cabal`), but in the tarball these entries actually _overwrite_
  each other (they all have the same filename). We need to define precisely
  how we deal with this.

[TUF]: http://theupdateframework.com/
[CabalHell1]: http://www.well-typed.com/blog/2014/09/how-we-might-abolish-cabal-hell-part-1/
[ZuriHac]: http://www.well-typed.com/blog/2015/06/cabal-hackage-hacking-at-zurihac/
[StackageNightly]: http://www.stackage.org/
[DebianJessie]: https://wiki.debian.org/DebianJessie
[Targetshs]: https://github.com/well-typed/hackage-security/blob/master/hackage-security/src/Hackage/Security/TUF/Targets.hs
[Patternshs]: https://github.com/well-typed/hackage-security/blob/master/hackage-security/src/Hackage/Security/TUF/Patterns.hs
