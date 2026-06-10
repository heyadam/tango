// Curated lucide-react → SF Symbols name map for the SwiftUI codegen and the
// preview host. Misses return a visible placeholder symbol — the design still
// renders, the gap is obvious, and growing this table is a one-line change.

export const SF_SYMBOL_FALLBACK = 'questionmark.square.dashed';

const MAP: Record<string, string> = {
  // navigation / chrome
  Search: 'magnifyingglass',
  Settings: 'gearshape',
  Settings2: 'gearshape.2',
  Menu: 'line.3.horizontal',
  MoreHorizontal: 'ellipsis',
  MoreVertical: 'ellipsis',
  ChevronRight: 'chevron.right',
  ChevronLeft: 'chevron.left',
  ChevronUp: 'chevron.up',
  ChevronDown: 'chevron.down',
  ArrowRight: 'arrow.right',
  ArrowLeft: 'arrow.left',
  ArrowUp: 'arrow.up',
  ArrowDown: 'arrow.down',
  X: 'xmark',
  Plus: 'plus',
  Minus: 'minus',
  Check: 'checkmark',
  CheckCircle: 'checkmark.circle',
  CheckCircle2: 'checkmark.circle.fill',
  Circle: 'circle',
  Home: 'house',
  House: 'house',
  // people
  User: 'person',
  Users: 'person.2',
  UserPlus: 'person.badge.plus',
  CircleUser: 'person.circle',
  // common objects
  Star: 'star',
  Heart: 'heart',
  Bell: 'bell',
  Calendar: 'calendar',
  Camera: 'camera',
  Mail: 'envelope',
  Lock: 'lock',
  Unlock: 'lock.open',
  Eye: 'eye',
  EyeOff: 'eye.slash',
  Image: 'photo',
  ImageIcon: 'photo',
  File: 'doc',
  FileText: 'doc.text',
  Folder: 'folder',
  FolderOpen: 'folder',
  Trash: 'trash',
  Trash2: 'trash',
  Bookmark: 'bookmark',
  Tag: 'tag',
  Gift: 'gift',
  ShoppingCart: 'cart',
  ShoppingBag: 'bag',
  CreditCard: 'creditcard',
  Wallet: 'wallet.pass',
  MapPin: 'mappin',
  Map: 'map',
  Globe: 'globe',
  Clock: 'clock',
  Timer: 'timer',
  // communication
  Send: 'paperplane',
  MessageCircle: 'message',
  MessageSquare: 'message',
  Phone: 'phone',
  Mic: 'mic',
  MicOff: 'mic.slash',
  Share: 'square.and.arrow.up',
  Share2: 'square.and.arrow.up',
  // media
  Play: 'play.fill',
  Pause: 'pause.fill',
  SkipForward: 'forward.end.fill',
  SkipBack: 'backward.end.fill',
  Music: 'music.note',
  Volume2: 'speaker.wave.2',
  VolumeX: 'speaker.slash',
  // status / actions
  Info: 'info.circle',
  AlertTriangle: 'exclamationmark.triangle',
  AlertCircle: 'exclamationmark.circle',
  HelpCircle: 'questionmark.circle',
  Download: 'arrow.down.circle',
  Upload: 'arrow.up.circle',
  RefreshCw: 'arrow.clockwise',
  RotateCcw: 'arrow.counterclockwise',
  Copy: 'doc.on.doc',
  Edit: 'pencil',
  Edit2: 'pencil',
  Edit3: 'pencil',
  Pencil: 'pencil',
  Filter: 'line.3.horizontal.decrease',
  SlidersHorizontal: 'slider.horizontal.3',
  LogOut: 'rectangle.portrait.and.arrow.right',
  LogIn: 'rectangle.portrait.and.arrow.forward',
  ExternalLink: 'arrow.up.right.square',
  Link: 'link',
  Paperclip: 'paperclip',
  ThumbsUp: 'hand.thumbsup',
  ThumbsDown: 'hand.thumbsdown',
  Flag: 'flag',
  Zap: 'bolt',
  Sun: 'sun.max',
  Moon: 'moon',
  Cloud: 'cloud',
  Wifi: 'wifi',
  Battery: 'battery.100',
  Bluetooth: 'wave.3.right',
  Sparkles: 'sparkles',
  Smile: 'face.smiling',
  Frame: 'square.dashed',
  Layers: 'square.3.layers.3d',
  Code: 'chevron.left.forwardslash.chevron.right',
  Code2: 'chevron.left.forwardslash.chevron.right',
  Terminal: 'terminal',
  Smartphone: 'iphone',
  Laptop: 'laptopcomputer',
  Monitor: 'display',
};

export function lucideToSfSymbol(name: string | undefined | null): string {
  if (!name) return 'circle'; // mirrors the web renderer's Circle default
  return MAP[name] ?? SF_SYMBOL_FALLBACK;
}

// MAP is many-to-one (Trash/Trash2 → 'trash', Edit*/Pencil → 'pencil', …), so
// the reverse direction needs canonical winners. Curated picks below; any
// other collision resolves to the FIRST entry in MAP order (a literal, so
// deterministic). Used by the import design scanner to turn an app's SF
// Symbol usage into canvas-addressable lucide icon names.
const REVERSE_CANONICAL: Record<string, string> = {
  ellipsis: 'MoreHorizontal',
  trash: 'Trash2', // the import prompt's pick
  pencil: 'Pencil',
  message: 'MessageCircle',
  'square.and.arrow.up': 'Share',
  photo: 'Image',
  house: 'Home',
  folder: 'Folder',
  'chevron.left.forwardslash.chevron.right': 'Code',
};

const REVERSE: Record<string, string> = (() => {
  const out: Record<string, string> = { ...REVERSE_CANONICAL };
  for (const [lucide, sf] of Object.entries(MAP)) {
    if (!(sf in out)) out[sf] = lucide;
  }
  return out;
})();

// SF Symbol → lucide name, with `.fill`/`.circle`-style suffixes retried
// bare so e.g. 'star.fill' still finds Star. Returns null for symbols the
// table can't represent.
export function sfSymbolToLucide(sfName: string): string | null {
  const direct = REVERSE[sfName];
  if (direct) return direct;
  const stripped = sfName.replace(/\.(fill|circle|square)$/, '');
  if (stripped !== sfName && REVERSE[stripped]) return REVERSE[stripped];
  return null;
}
