import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  _iosScreenScanCacheSizeForTests,
  checkScanScope,
  detectEntryIds,
  parseStoryboardEdges,
  parseStoryboardScreens,
  parseSwiftEdges,
  parseSwiftUIScreens,
  parseUIKitScreens,
  resetIosScreenScanCache,
  scanIosScreens,
  shouldSkipDir,
  shouldSkipFile,
} from './iosScreenScan';
import { callHook } from './serverHooks';
import {
  layoutScreenFlow,
  screenFlowDiagnostics,
  validateScreenFlowInput,
} from './screenFlow';

describe('parseSwiftUIScreens', () => {
  it('matches a top-level View struct', () => {
    const src = `
import SwiftUI

struct Home: View {
  var body: some View { Text("hi") }
}
`;
    const screens = parseSwiftUIScreens(src, 'Home.swift', false);
    expect(screens).toHaveLength(1);
    expect(screens[0].id).toBe('Home');
    expect(screens[0].kind).toBe('swiftui');
  });

  it('skips nested types (column-zero anchor)', () => {
    const src = `
struct Outer: View {
  struct Inner: View {
    var body: some View { Text("inner") }
  }
  var body: some View { Inner() }
}
`;
    const screens = parseSwiftUIScreens(src, 'Outer.swift', false);
    expect(screens.map((s) => s.id)).toEqual(['Outer']);
  });

  it('handles access modifiers, final, and generics', () => {
    const src = `
public struct PublicView: View { var body: some View { EmptyView() } }
final struct FinalView: View { var body: some View { EmptyView() } }
struct Generic<Content: View>: View { let c: Content; var body: some View { c } }
`;
    const screens = parseSwiftUIScreens(src, 'a.swift', false);
    expect(screens.map((s) => s.id).sort()).toEqual([
      'FinalView',
      'Generic',
      'PublicView',
    ]);
  });

  it('extracts a one-line summary from the first Text literal when requested', () => {
    const src = `
struct Login: View {
  var body: some View {
    VStack {
      Text("Sign in to continue")
      TextField("email", text: $email)
    }
  }
}
`;
    const withSummary = parseSwiftUIScreens(src, 'Login.swift', true);
    expect(withSummary[0].summary).toBe('Sign in to continue');

    const without = parseSwiftUIScreens(src, 'Login.swift', false);
    expect(without[0].summary).toBeUndefined();
  });
});

describe('parseUIKitScreens', () => {
  it('matches UIViewController subclasses', () => {
    const src = `
final class HomeViewController: UIViewController {}
class ProfileVC: BaseVC {}
`;
    const screens = parseUIKitScreens(src, 'a.swift');
    expect(screens.map((s) => s.id).sort()).toEqual([
      'HomeViewController',
      'ProfileVC',
    ]);
    expect(screens.every((s) => s.kind === 'uikit')).toBe(true);
  });

  it('skips classes whose conformance does not end in ViewController/VC', () => {
    const src = `
class HomeViewModel: ObservableObject {}
class Helper: NSObject {}
`;
    expect(parseUIKitScreens(src, 'a.swift')).toEqual([]);
  });
});

describe('parseStoryboardScreens', () => {
  it('captures viewController by customClass when present', () => {
    const xml = `
<viewController customClass="LoginViewController" id="abc-1">
</viewController>
<viewController id="def-2">
</viewController>
`;
    const screens = parseStoryboardScreens(xml, 'Main.storyboard');
    expect(screens).toHaveLength(2);
    expect(screens[0].id).toBe('LoginViewController');
    expect(screens[1].id).toBe('def-2');
    expect(screens[1].name).toMatch(/Def/);
  });

  it('captures customClass even when id appears first (Xcode default order)', () => {
    // Real Xcode emits id before customClass — the regex must not be order-
    // sensitive. Pre-fix this test would fail with id="abc-1" winning.
    const xml = `
<viewController id="abc-1" customClass="LoginViewController">
</viewController>
`;
    const screens = parseStoryboardScreens(xml, 'Main.storyboard');
    expect(screens[0].id).toBe('LoginViewController');
  });

  it('captures customClass when other attributes sit between it and id', () => {
    const xml = `
<viewController storyboardIdentifier="LoginScene" id="abc" sceneMemberID="viewController" customClass="LoginVC">
</viewController>
`;
    const screens = parseStoryboardScreens(xml, 'Main.storyboard');
    expect(screens[0].id).toBe('LoginVC');
  });
});

describe('parseSwiftEdges', () => {
  it('classifies NavigationLink / sheet / fullScreenCover / present', () => {
    const src = `
NavigationLink(destination: Detail()) { Text("go") }
.sheet(isPresented: $showing) { Onboarding() }
.fullScreenCover(isPresented: $cover) { Tutorial() }
present(EditorVC(), animated: true)
`;
    const edges = parseSwiftEdges(src, 'Home');
    const byKind = Object.fromEntries(edges.map((e) => [e.kind, e.to]));
    expect(byKind.push).toBe('Detail');
    expect(byKind.sheet).toBe('Onboarding');
    expect(byKind.cover).toBe('Tutorial');
    expect(byKind.present).toBe('EditorVC');
  });

  it('classifies pushViewController as push', () => {
    const src = `navigationController?.pushViewController(DetailVC(), animated: true)`;
    const edges = parseSwiftEdges(src, 'HomeVC');
    expect(edges).toEqual([{ from: 'HomeVC', to: 'DetailVC', kind: 'push' }]);
  });

  it('classifies TabView children as tab edges', () => {
    const src = `
TabView {
  HomeView()
  SearchView()
  ProfileView()
}
`;
    const edges = parseSwiftEdges(src, 'Root');
    expect(edges.map((e) => e.kind)).toEqual(['tab', 'tab', 'tab']);
    expect(edges.map((e) => e.to).sort()).toEqual([
      'HomeView',
      'ProfileView',
      'SearchView',
    ]);
  });

  it('filters non-destination SwiftUI value types from TabView children', () => {
    // TabView blocks routinely contain Color/Image/EmptyView/Text — these
    // are PascalCase but never navigation destinations. Pre-fix they showed
    // up as dangling-edge diagnostics noise.
    const src = `
TabView {
  HomeView()
  Color(.red)
  Image("placeholder")
  EmptyView()
  Text("hi")
  RealTab()
}
`;
    const edges = parseSwiftEdges(src, 'Root');
    expect(edges.map((e) => e.to).sort()).toEqual(['HomeView', 'RealTab']);
  });

  it('skips self-references and lowercase identifiers', () => {
    const src = `
NavigationLink(destination: Self()) { ... }
.sheet(isPresented: $show) { localFn() }
`;
    const edges = parseSwiftEdges(src, 'Self');
    expect(edges).toEqual([]);
  });

  it('captures the destination after a helper-call inside the closure body', () => {
    // Pre-fix the lazy `\b\w+\(` regex matched the helper first → push()
    // dropped it for being lowercase → the real destination was lost. Now
    // the regex requires PascalCase, skipping the helper entirely.
    const src = `
.sheet(isPresented: $show) {
  let _ = trackOpen()
  helperFn()
  RealDestination()
}
`;
    const edges = parseSwiftEdges(src, 'Home');
    expect(edges).toEqual([
      { from: 'Home', to: 'RealDestination', kind: 'sheet' },
    ]);
  });

  it('de-duplicates identical (to, kind) pairs', () => {
    const src = `
NavigationLink(destination: Detail()) {}
NavigationLink(destination: Detail()) {}
`;
    const edges = parseSwiftEdges(src, 'Home');
    expect(edges).toHaveLength(1);
  });
});

describe('parseStoryboardEdges', () => {
  it('translates segue kind to push / sheet / segue', () => {
    // Wrap in a viewController scene so segues have an attribution source —
    // segues at file scope (no enclosing scene) are unattributable and
    // correctly dropped.
    const xml = `
<viewController id="home-1">
  <segue destination="dest-a" kind="show" />
  <segue destination="dest-b" kind="modal" />
  <segue destination="dest-c" kind="custom" />
  <segue destination="dest-d" />
</viewController>
<viewController id="dest-a"></viewController>
<viewController id="dest-b"></viewController>
<viewController id="dest-c"></viewController>
<viewController id="dest-d"></viewController>
`;
    const edges = parseStoryboardEdges(xml);
    expect(
      edges.map((e) => `${e.from}:${e.to}:${e.kind}`).sort(),
    ).toEqual([
      'home-1:dest-a:push',
      'home-1:dest-b:sheet',
      'home-1:dest-c:segue',
      'home-1:dest-d:segue',
    ]);
  });

  it('attributes each segue to its enclosing viewController in multi-VC storyboards', () => {
    // Pre-fix every segue was attributed to the file's first scene, which
    // collapsed multi-VC storyboard navigation into a single source.
    const xml = `
<viewController customClass="LoginVC" id="login-1">
  <connections>
    <segue destination="dashboard-2" kind="show" />
  </connections>
</viewController>
<viewController customClass="DashboardVC" id="dashboard-2">
  <connections>
    <segue destination="settings-3" kind="modal" />
  </connections>
</viewController>
<viewController customClass="SettingsVC" id="settings-3"></viewController>
`;
    const edges = parseStoryboardEdges(xml);
    expect(
      edges.map((e) => `${e.from}:${e.to}:${e.kind}`).sort(),
    ).toEqual([
      'DashboardVC:SettingsVC:sheet',
      'LoginVC:DashboardVC:push',
    ]);
  });

  it('translates destination scene ids through the customClass map', () => {
    // Pre-fix destination="login-1" emitted edges to "login-1" while the
    // screen was registered as "LoginVC" — every customClassed destination
    // dangled. The translation step is the load-bearing fix.
    const xml = `
<viewController customClass="HomeVC" id="home-1">
  <connections>
    <segue destination="login-2" kind="show" />
  </connections>
</viewController>
<viewController customClass="LoginVC" id="login-2"></viewController>
`;
    const edges = parseStoryboardEdges(xml);
    expect(edges).toEqual([
      { from: 'HomeVC', to: 'LoginVC', kind: 'push' },
    ]);
  });

  it('keeps cross-storyboard destination ids as-is so they surface as dangling downstream', () => {
    const xml = `
<viewController customClass="HomeVC" id="home-1">
  <connections>
    <segue destination="external-scene" kind="show" />
  </connections>
</viewController>
`;
    const edges = parseStoryboardEdges(xml);
    expect(edges).toEqual([
      { from: 'HomeVC', to: 'external-scene', kind: 'push' },
    ]);
  });

  it('leaves self-closing viewControllers contributing no edges', () => {
    const xml = `
<viewController customClass="EmptyVC" id="empty-1" />
<viewController customClass="HomeVC" id="home-2">
  <connections>
    <segue destination="empty-1" kind="show" />
  </connections>
</viewController>
`;
    const edges = parseStoryboardEdges(xml);
    expect(edges).toEqual([
      { from: 'HomeVC', to: 'EmptyVC', kind: 'push' },
    ]);
  });
});

describe('detectEntryIds', () => {
  it('finds @main + WindowGroup root', () => {
    const src = `
@main
struct App: App {
  var body: some Scene { WindowGroup { RootView() } }
}
`;
    expect(detectEntryIds(src, 'swift')).toEqual(['RootView']);
  });

  it('does not return WindowGroup roots without @main', () => {
    const src = `WindowGroup { RootView() }`;
    expect(detectEntryIds(src, 'swift')).toEqual([]);
  });

  it('finds AppDelegate.window.rootViewController', () => {
    const src = `
window?.rootViewController = HomeNavigationController()
`;
    expect(detectEntryIds(src, 'swift')).toEqual(['HomeNavigationController']);
  });

  it('finds storyboard isInitialViewController', () => {
    const xml = `
<viewController customClass="LoginVC" id="abc" isInitialViewController="YES">
</viewController>
`;
    expect(detectEntryIds(xml, 'storyboard')).toEqual(['LoginVC']);
  });
});

describe('skip set', () => {
  it('skips well-known build / vendor dirs', () => {
    expect(shouldSkipDir('Pods')).toBe(true);
    expect(shouldSkipDir('.build')).toBe(true);
    expect(shouldSkipDir('DerivedData')).toBe(true);
    expect(shouldSkipDir('Preview Content')).toBe(true);
    expect(shouldSkipDir('Sources')).toBe(false);
  });

  it('skips xcassets / xcdatamodel directories', () => {
    expect(shouldSkipDir('Assets.xcassets')).toBe(true);
    expect(shouldSkipDir('Model.xcdatamodel')).toBe(true);
    expect(shouldSkipDir('Model.xcdatamodeld')).toBe(true);
  });

  it('skips test files', () => {
    expect(shouldSkipFile('/x/AppTests.swift')).toBe(true);
    expect(shouldSkipFile('/x/AppUITests.swift')).toBe(true);
    expect(shouldSkipFile('/x/Sub/Tests/Foo.swift')).toBe(true);
    expect(shouldSkipFile('/x/Sub/UITests/Foo.swift')).toBe(true);
    expect(shouldSkipFile('/x/HomePreviews.swift')).toBe(true);
    expect(shouldSkipFile('/x/Home.swift')).toBe(false);
  });
});

describe('checkScanScope', () => {
  let workspace: string;

  beforeEach(async () => {
    workspace = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-scope-'));
  });

  afterEach(async () => {
    await fs.rm(workspace, { recursive: true, force: true });
  });

  it('accepts no rootDir when a workspace is set', async () => {
    const result = await checkScanScope(undefined, workspace);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.absRoot).toBe(path.resolve(workspace));
  });

  it('rejects no rootDir when no workspace is set', async () => {
    const result = await checkScanScope(undefined, null);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/no workspace/);
  });

  it('rejects rootDir override when no workspace is set', async () => {
    // Even with a fully-qualified absolute path, an unanchored override is
    // refused — workspace=null is not a license to scan arbitrary paths.
    const result = await checkScanScope(workspace, null);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/require a workspace/);
  });

  it('rejects relative rootDir', async () => {
    const result = await checkScanScope('app/sources', workspace);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/absolute path/);
  });

  it('accepts an absolute rootDir inside the workspace', async () => {
    const inside = path.join(workspace, 'app');
    await fs.mkdir(inside, { recursive: true });
    const result = await checkScanScope(inside, workspace);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.absRoot).toBe(await fs.realpath(inside));
  });

  it('rejects a rootDir that escapes the workspace via "..".', async () => {
    const outside = path.join(workspace, '..', 'sibling');
    const result = await checkScanScope(outside, workspace);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/inside the active workspace/);
  });

  it('rejects a rootDir that escapes via a symlink target', async () => {
    // `linked/` lives inside the workspace lexically, but symlinks to a
    // sibling dir outside it. Lexical containment is fooled; realpath
    // containment must catch it.
    const sibling = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-sibling-'));
    try {
      const linked = path.join(workspace, 'linked');
      try {
        await fs.symlink(sibling, linked, 'dir');
      } catch {
        // Filesystem may disallow symlinks; skip.
        return;
      }
      const result = await checkScanScope(linked, workspace);
      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.reason).toMatch(/symlink|outside the active workspace/);
      }
    } finally {
      await fs.rm(sibling, { recursive: true, force: true });
    }
  });
});

describe('scanIosScreens (file walk + cache)', () => {
  let root: string;

  beforeEach(async () => {
    resetIosScreenScanCache();
    root = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-scan-'));
  });

  afterEach(async () => {
    await fs.rm(root, { recursive: true, force: true });
  });

  it('walks .swift + .storyboard and returns relative file paths', async () => {
    await fs.mkdir(path.join(root, 'App'), { recursive: true });
    await fs.writeFile(
      path.join(root, 'App', 'Home.swift'),
      `struct Home: View { var body: some View { NavigationLink(destination: Detail()) {} } }`,
    );
    await fs.writeFile(
      path.join(root, 'App', 'Detail.swift'),
      `struct Detail: View { var body: some View { EmptyView() } }`,
    );

    const result = await scanIosScreens({ rootDir: root });
    expect(result.screens.map((s) => s.id).sort()).toEqual(['Detail', 'Home']);
    expect(result.edges).toEqual([
      { from: 'Home', to: 'Detail', kind: 'push' },
    ]);
    expect(result.screens[0].filePath?.startsWith('App/')).toBe(true);
  });

  it('skips Pods / .build / DerivedData / *.xcassets / Tests', async () => {
    for (const dir of ['Pods', '.build', 'Preview Content', 'Tests', 'Assets.xcassets']) {
      await fs.mkdir(path.join(root, dir), { recursive: true });
      await fs.writeFile(
        path.join(root, dir, 'Hidden.swift'),
        `struct Hidden: View { var body: some View { EmptyView() } }`,
      );
    }
    await fs.writeFile(
      path.join(root, 'Visible.swift'),
      `struct Visible: View { var body: some View { EmptyView() } }`,
    );
    const result = await scanIosScreens({ rootDir: root });
    expect(result.screens.map((s) => s.id)).toEqual(['Visible']);
    expect(result.skippedDirs).toBeGreaterThanOrEqual(4);
  });

  it('caches by file mtime — second call has cachedFiles>0', async () => {
    await fs.writeFile(
      path.join(root, 'A.swift'),
      `struct A: View { var body: some View { EmptyView() } }`,
    );
    const first = await scanIosScreens({ rootDir: root });
    expect(first.scannedFiles).toBe(1);
    expect(first.cachedFiles).toBe(0);

    const second = await scanIosScreens({ rootDir: root });
    expect(second.scannedFiles).toBe(0);
    expect(second.cachedFiles).toBe(1);
    expect(second.screens.map((s) => s.id)).toEqual(['A']);
  });

  it('invalidates cache when a file is modified', async () => {
    const fp = path.join(root, 'A.swift');
    await fs.writeFile(fp, `struct A: View { var body: some View { EmptyView() } }`);
    await scanIosScreens({ rootDir: root });

    // Touch with a future mtime so the cache miss is unambiguous on filesystems
    // with low mtime resolution.
    const future = new Date(Date.now() + 5000);
    await fs.utimes(fp, future, future);
    await fs.writeFile(
      fp,
      `struct A: View { var body: some View { EmptyView() } }
struct B: View { var body: some View { EmptyView() } }`,
    );
    await fs.utimes(fp, future, future);

    const after = await scanIosScreens({ rootDir: root });
    expect(after.scannedFiles).toBe(1);
    expect(after.screens.map((s) => s.id).sort()).toEqual(['A', 'B']);
  });

  it('resetIosScreenScanCache forces a fresh scan', async () => {
    await fs.writeFile(
      path.join(root, 'A.swift'),
      `struct A: View { var body: some View { EmptyView() } }`,
    );
    await scanIosScreens({ rootDir: root });
    resetIosScreenScanCache();
    const after = await scanIosScreens({ rootDir: root });
    expect(after.scannedFiles).toBe(1);
    expect(after.cachedFiles).toBe(0);
  });

  it('marks @main WindowGroup root as isEntry', async () => {
    await fs.writeFile(
      path.join(root, 'App.swift'),
      `@main struct AppRoot: App { var body: some Scene { WindowGroup { Home() } } }`,
    );
    await fs.writeFile(
      path.join(root, 'Home.swift'),
      `struct Home: View { var body: some View { EmptyView() } }`,
    );
    const result = await scanIosScreens({ rootDir: root });
    const home = result.screens.find((s) => s.id === 'Home');
    expect(home?.isEntry).toBe(true);
  });

  it('honors includeSummaries and re-scans when toggled', async () => {
    await fs.writeFile(
      path.join(root, 'Home.swift'),
      `struct Home: View { var body: some View { Text("Welcome home") } }`,
    );
    const noSummaries = await scanIosScreens({ rootDir: root });
    expect(noSummaries.screens[0].summary).toBeUndefined();

    const withSummaries = await scanIosScreens({
      rootDir: root,
      includeSummaries: true,
    });
    expect(withSummaries.screens[0].summary).toBe('Welcome home');
  });

  it('keeps summaries out of the no-summary path on a true→false toggle', async () => {
    // Pre-fix, the cache aliased the summary-bearing entry under the bare
    // path key, so a second `includeSummaries:false` scan would silently
    // return summary-bearing cached results.
    await fs.writeFile(
      path.join(root, 'Home.swift'),
      `struct Home: View { var body: some View { Text("Welcome home") } }`,
    );
    const first = await scanIosScreens({ rootDir: root, includeSummaries: true });
    expect(first.screens[0].summary).toBe('Welcome home');

    const second = await scanIosScreens({ rootDir: root });
    expect(second.screens[0].summary).toBeUndefined();
  });

  it('returns workspace-relative filePaths even when the same file is scanned via two rootDirs', async () => {
    // Pre-fix the cached `screens[].filePath` was mutated in place to be
    // relative to the first scan's `rootDir`; the second scan with a
    // different rootDir returned the previous root's relative path.
    await fs.mkdir(path.join(root, 'sub', 'app'), { recursive: true });
    const filePath = path.join(root, 'sub', 'app', 'Home.swift');
    await fs.writeFile(
      filePath,
      `struct Home: View { var body: some View { EmptyView() } }`,
    );

    const fromRoot = await scanIosScreens({ rootDir: root });
    expect(fromRoot.screens[0].filePath).toBe(path.join('sub', 'app', 'Home.swift'));

    const fromSub = await scanIosScreens({ rootDir: path.join(root, 'sub') });
    expect(fromSub.screens[0].filePath).toBe(path.join('app', 'Home.swift'));

    // First call's result should not have been retroactively mutated.
    expect(fromRoot.screens[0].filePath).toBe(path.join('sub', 'app', 'Home.swift'));
  });

  it('evicts cache entries for files that disappear between scans', async () => {
    const aPath = path.join(root, 'A.swift');
    const bPath = path.join(root, 'B.swift');
    await fs.writeFile(
      aPath,
      `struct A: View { var body: some View { EmptyView() } }`,
    );
    await fs.writeFile(
      bPath,
      `struct B: View { var body: some View { EmptyView() } }`,
    );
    const first = await scanIosScreens({ rootDir: root });
    expect(first.screens.map((s) => s.id).sort()).toEqual(['A', 'B']);
    expect(_iosScreenScanCacheSizeForTests()).toBe(2);

    await fs.rm(aPath);
    const second = await scanIosScreens({ rootDir: root });
    expect(second.screens.map((s) => s.id)).toEqual(['B']);
    // Cache must actually shrink — the eviction loop is the load-bearing
    // piece here, and a no-op implementation would still pass the screens
    // assertion above.
    expect(_iosScreenScanCacheSizeForTests()).toBe(1);
  });

  it('keeps no-summary entries out of summary-bearing cache on a false→true toggle', async () => {
    // Symmetric to the true→false test above. The cache key flips namespace
    // (`abs` vs `abs|s`); a future refactor that fuses them would surface
    // here.
    await fs.writeFile(
      path.join(root, 'Home.swift'),
      `struct Home: View { var body: some View { Text("Welcome home") } }`,
    );
    const first = await scanIosScreens({ rootDir: root });
    expect(first.screens[0].summary).toBeUndefined();
    expect(_iosScreenScanCacheSizeForTests()).toBe(1);

    const second = await scanIosScreens({ rootDir: root, includeSummaries: true });
    expect(second.screens[0].summary).toBe('Welcome home');
    // Both modes' entries coexist in the cache.
    expect(_iosScreenScanCacheSizeForTests()).toBe(2);
  });

  it('cache-hit path returns filePaths fresh-relative to the second rootDir', async () => {
    // First scan from `root` populates the cache with absolute paths. The
    // second scan from `root/sub` must hit the cache (mtime unchanged) but
    // re-relativize on the way out.
    await fs.mkdir(path.join(root, 'sub', 'app'), { recursive: true });
    const filePath = path.join(root, 'sub', 'app', 'Home.swift');
    await fs.writeFile(
      filePath,
      `struct Home: View { var body: some View { EmptyView() } }`,
    );

    const fromRoot = await scanIosScreens({ rootDir: root });
    expect(fromRoot.screens[0].filePath).toBe(path.join('sub', 'app', 'Home.swift'));

    const fromSub = await scanIosScreens({ rootDir: path.join(root, 'sub') });
    // Must be a cache hit — the file didn't change.
    expect(fromSub.cachedFiles).toBe(1);
    expect(fromSub.scannedFiles).toBe(0);
    // ...but the relative path is the second root's, not the first's.
    expect(fromSub.screens[0].filePath).toBe(path.join('app', 'Home.swift'));
    // First call's result should not have been retroactively mutated.
    expect(fromRoot.screens[0].filePath).toBe(path.join('sub', 'app', 'Home.swift'));
  });

  it('round-trips cleanly into the screen-flow layout pipeline (no dangling edges)', async () => {
    // The load-bearing happy path the patch was built for. A real-shape
    // mini-project should produce a graph that validates and lays out
    // without dangling-edge diagnostics.
    await fs.writeFile(
      path.join(root, 'App.swift'),
      `@main struct AppRoot: App { var body: some Scene { WindowGroup { Home() } } }`,
    );
    await fs.writeFile(
      path.join(root, 'Home.swift'),
      `struct Home: View {
  var body: some View {
    NavigationLink(destination: Detail()) { Text("Open") }
  }
}`,
    );
    await fs.writeFile(
      path.join(root, 'Detail.swift'),
      `struct Detail: View { var body: some View { EmptyView() } }`,
    );
    const result = await scanIosScreens({ rootDir: root });
    expect(validateScreenFlowInput(result.screens, result.edges)).toBeNull();
    const layout = layoutScreenFlow(result.screens, result.edges);
    const diag = screenFlowDiagnostics(result.screens, result.edges, layout);
    expect(diag.danglingEdges).toEqual([]);
    expect(diag.layoutOverlaps).toEqual([]);
    const home = result.screens.find((s) => s.id === 'Home');
    expect(home?.isEntry).toBe(true);
  });

  it('follows symlinked source files without infinite-looping on cycles', async () => {
    // Some monorepo-style iOS targets symlink shared modules. The walker
    // must follow the link (so the screens show up) and tolerate cycles
    // (so a self-referential symlink doesn't blow the stack).
    const realDir = path.join(root, 'real');
    const linkDir = path.join(root, 'linked');
    await fs.mkdir(realDir, { recursive: true });
    await fs.writeFile(
      path.join(realDir, 'Shared.swift'),
      `struct Shared: View { var body: some View { EmptyView() } }`,
    );
    try {
      await fs.symlink(realDir, linkDir, 'dir');
    } catch {
      // Some CI filesystems disallow symlinks; skip without failing.
      return;
    }
    // Cycle: a self-referential symlink under the real dir.
    try {
      await fs.symlink(realDir, path.join(realDir, 'self-loop'), 'dir');
    } catch {
      // ignore
    }

    const result = await scanIosScreens({ rootDir: root });
    // The realpath visited-set ensures `Shared` is captured exactly once
    // even though it's reachable via two paths.
    expect(result.screens.filter((s) => s.id === 'Shared')).toHaveLength(1);
  });

  it('clears the cache when the resetIosScan hook fires (workspace switch)', async () => {
    // The hook chain in workspaceState.ts:setWorkspace fires
    // `callHook('resetIosScan')` on every workspace change. iosScreenScan
    // registers against that key on import; this test pins the wiring so a
    // future refactor that drops the registration would surface here.
    await fs.writeFile(
      path.join(root, 'A.swift'),
      `struct A: View { var body: some View { EmptyView() } }`,
    );
    await scanIosScreens({ rootDir: root });
    expect(_iosScreenScanCacheSizeForTests()).toBeGreaterThan(0);

    callHook('resetIosScan');
    expect(_iosScreenScanCacheSizeForTests()).toBe(0);

    // Subsequent scan should re-read the file (cache miss), confirming the
    // hook actually wiped state and didn't just fail silently.
    const after = await scanIosScreens({ rootDir: root });
    expect(after.scannedFiles).toBe(1);
    expect(after.cachedFiles).toBe(0);
  });

  it('tolerates a broken symlink without crashing', async () => {
    // Some Xcode templates leave dead symlinks behind (deleted target, etc.).
    // The walker should skip the broken link and finish normally.
    await fs.writeFile(
      path.join(root, 'Real.swift'),
      `struct Real: View { var body: some View { EmptyView() } }`,
    );
    try {
      await fs.symlink('/nonexistent-target-xyz', path.join(root, 'broken'), 'file');
    } catch {
      return;
    }
    const result = await scanIosScreens({ rootDir: root });
    expect(result.screens.map((s) => s.id)).toEqual(['Real']);
  });
});
