/* Which usernames and names Chausima won't give out.
   1. Kept usernames: names that could make someone look like they speak for Chausima, HWL, the Launchpad,
      a school, a company people trust, or a service account. Checked after "un-disguising" (0→o, 1→i, dots,
      underscores and numbers taken out), so admin_2, 0fficial and support.team are caught too.
   2. Kept roots: if one of these appears anywhere in the username, it's refused (e.g. "chausimasupport").
   3. Rude words: swearing, sexual words and slurs, in usernames and names. Short words only count as a whole
      word, so "class", "Scunthorpe" or "assignment" are fine; longer words count anywhere. */

const KEPT = `
admin administrator administration admins root sysadmin superuser superadmin sudo owner owners founder cofounder ceo cto
support supportteam helpdesk help helper helpers service services customerservice customercare care contact contactus
info information enquiries enquiry office team staff staffroom crew official officials verified verify verification
moderator moderators mod mods modteam security secure safety safeguarding trust trustandsafety abuse report reports
postmaster hostmaster webmaster mailer daemon mailerdaemon noreply donotreply reply mail email emails inbox
system systems server servers bot bots robot automated automation api dev developer developers devteam engineering
billing payments payment accounts account accountant finance refunds refund sales shop store orders
legal privacy terms policy compliance copyright dmca press media news newsletter announcements updates alerts status
test tester testing testuser demo example sample guest anonymous anon unknown user username nobody null undefined
chausima chausimamail chausimasuite chausimaid ctube hwl hwlsystems hwlai hwladmin hwlbrowser hwlsearch hwlos
launchpad homeworklaunchpad civilinitiatives levelup suite docs sheets slides forms
shiv shivkumar shivk kumar heh hehs hehlive
school headteacher headmaster headmistress deputyhead principal teacher teachers tutor formtutor senco
hatchend hatchendhigh harrow harrowcouncil council governor governors pupil pupils student students parent parents
police gov government nhs childline nspcc ofsted
google gmail youtube android chrome microsoft outlook office365 teams windows xbox apple icloud iphone ipad
amazon meta facebook instagram whatsapp tiktok snapchat discord roblox minecraft mojang fortnite epicgames
steam playstation nintendo twitch reddit twitter netflix spotify openai chatgpt anthropic claude bbc
oracle github paypal stripe visa mastercard bank`;
const ROOTS = ["admin", "moderator", "official", "support", "helpdesk", "chausima", "hwlsystems", "launchpad", "civilinitiatives",
  "headteacher", "safeguard", "verified", "security", "postmaster", "noreply", "anthropic", "openai", "microsoft", "google", "youtube"];

/* rude words (kept short and generic on purpose) */
const RUDE_WHOLE = `ass arse anal anus bum cum coon cock dick dyke fag fags homo jap kike nob nonce paki pussy rape
sex sexy slag slut spic tit tits twat wank wog boob boobs porn piss poo poop crap fuk fuq fck fk kys nazi
cunt hoe hoes knob weed meth isis prick minge pedo fack fuc`;
const RUDE_ANY = ["fuck", "shit", "bitch", "bastard", "bollock", "wanker", "whore", "nigger", "nigga", "faggot",
  "retard", "rapist", "rapey", "porn", "penis", "vagina", "dildo", "blowjob", "handjob", "orgasm", "horny", "nude", "naked",
  "boner", "erection", "masturb", "paedo", "hitler", "heilhitler", "killyourself", "suicide", "selfharm", "terrorist",
  "kkk", "motherf", "asshole", "arsehole", "dickhead", "shithead", "jackass", "dumbass", "tosser",
  "bellend", "skank", "milf", "onlyfans", "xxx", "fck", "fcuk", "phuck", "sexting", "nsfw", "hentai", "cocaine", "heroin", "stoner"];
/* ordinary words that happen to contain a rude word */
const INNOCENT_RUDE = ["therapist", "therapy"];
/* real first names and surnames that are also rude words: fine in a person's name */
const NAME_OK = new Set(["dick", "willy", "fanny", "cock", "bum"]);
/* ordinary words that happen to contain a kept root */
const INNOCENT = ["badminton"];

const keptSet = new Set(KEPT.split(/\s+/).filter(Boolean));
const rudeWhole = new Set(RUDE_WHOLE.split(/\s+/).filter(Boolean));
export const KEPT_COUNT = keptSet.size;

const LEET: Record<string, string> = { "*": "u", "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "@": "a", "$": "s", "!": "i", "|": "i", "+": "t" };
function undisguise(s: string) {
  return s.toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/[*0134578@$!|+]/g, (c) => LEET[c]);
}
/* letters only, numbers taken out entirely (so admin2 -> admin) */
const squash = (s: string) => s.toLowerCase().replace(/[^a-z]/g, "");
const unrepeat = (s: string) => s.replace(/(.)\1{2,}/g, "$1$1");

function rude(text: string, isName = false): boolean {
  const raw = text.toLowerCase();
  const forms = [raw, undisguise(raw)];
  for (const f of forms) {
    const words = f.split(/[^a-z]+/).filter(Boolean);
    for (const w of words) {
      if (isName && NAME_OK.has(w)) continue;
      if (rudeWhole.has(w) || rudeWhole.has(unrepeat(w).replace(/(.)\1+/g, "$1"))) return true;
    }
    let sq = squash(f); for (const ok of INNOCENT_RUDE) sq = sq.split(ok).join("");
    for (const all of [sq, unrepeat(sq)]) for (const r of RUDE_ANY) if (all.includes(r)) return true;
  }
  return false;
}

/* returns null if OK, otherwise the reason to show */
export function usernameProblem(username: string): string | null {
  const plain = squash(undisguise(username)), digitsGone = squash(username);
  for (let v of [plain, digitsGone]) {
    for (const ok of INNOCENT) v = v.split(ok).join("");
    if (keptSet.has(v) || keptSet.has(plain) || keptSet.has(digitsGone)) return "That username is kept so nobody can pretend to be Chausima, a school or a company. Pick another.";
    if (ROOTS.some((r) => v.includes(r))) return "Usernames can't include words like admin, official, support or Chausima's own names. Pick another.";
  }
  if (rude(username)) return "That username isn't allowed. Pick something friendlier.";
  return null;
}
export function nameProblem(name: string): string | null {
  if (rude(name, true)) return "That name isn't allowed. Use your real first name or a friendly nickname.";
  const plain = squash(undisguise(name));
  if (["chausima", "hwladmin", "hwlsystems", "administrator", "moderator", "official", "headteacher"].some((r) => plain.includes(r)) ||
      ["admin", "support", "helpdesk", "staff", "team", "security"].some((r) => plain === r || (plain.endsWith(r) && plain.length < 20)))
    return "Names can't make you look like Chausima staff. Use your own name.";
  return null;
}
