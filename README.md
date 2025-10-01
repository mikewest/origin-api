# An `Origin` API.
_Mike West, July 2025_

## A Problem

The [origin](https://html.spec.whatwg.org/multipage/browsers.html#origin) is a fundamental component of the web's implementation, essential to both the security and privacy boundaries which user agents maintain. The concept is well-defined between HTML and URL, along with widely-used adjacent concepts like "site".

Origins, however, are not directly exposed to web developers. Though there are various `origin` getters on various objects, each of those returns the [serialization](https://html.spec.whatwg.org/multipage/browsers.html#ascii-serialisation-of-an-origin) of an origin, not the origin itself. This has a few negative implications. Practically, developers attempting to do same-origin or same-site comparisons when handling serialized origins often get things wrong in ways that lead to vulnerabilities (see [PMForce: Systematically Analyzing postMessage Handlers at Scale](https://swag.cispa.saarland/papers/steffens2020pmforce.pdf) (Steffens and Stock, 2020) as one illuminating study). Philosophically, it seems like a missing security primitive that developers struggle to polyfill accurately.

## A Proposal

One way of approaching this gap would be to define an `Origin` object which represented the concept, enabling direct same-origin and same-site comparisons. In order to do so, we'd need to define a parser for serialized origins, just as we do for serialized URLs, and it might be helpful to support more complicated comparisons by introducing an `OriginPattern` object as an analog to `URLPattern`.

### An `Origin` Object

Let's consider a minimal `Origin` object that can be constructed from a string representing a serialized origin, and that offers two methods (`isSameOrigin()` and `isSameSite()`).

```javascript
// Tuple Origins
const origin = new Origin("https://origin.example");
const portedOrigin = new Origin("https://origin.example:8443");
const sameSiteOrigin = new Origin("https://sub.origin.example");
const notSameSiteOrigin = new Origin("http://other.example");

origin.isSameOrigin(origin);          // True!
origin.isSameOrigin(portedOrigin);    // False!
origin.isSameOrigin(sameSiteOrigin);  // False!

origin.isSameSite(portedOrigin);      // True!
origin.isSameSite(sameSiteOrigin);    // True!
origin.isSameSite(notSameSiteOrigin); // False!

// Opaque Origins
const opaqueOrigin = new Origin();
const otherOpaqueOrigin = Origin.parse("null");

opaqueOrigin.isSameOrigin(opaqueOrigin);      // True!
opaqueOrigin.isSameOrigin(otherOpaqueOrigin); // False!

// Invalid Origins
const invalidOrigin = [
  Origin.parse("invalid"),                  // null (the built-in primitive,
  Origin.parse("about:blank"),              // null  not the string "null")
  Origin.parse("https://u:p@site.example"), // null
  Origin.parse("https://ümlauted.example"), // null
  Origin.parse("https://trailing.slash/"),  // null
  Origin.parse("http://1234567890"),        // null
];
try {
  new Origin("invalid");
} catch (e) {
  // TypeError
}

// Serialization
origin.toString() === "https://origin.example" // True!
opaqueOrigin.toString() === "null"             // True!
```

This seems like it satisfies the core use cases that we'd like developers to be able to handle without resorting to string-based comparisons. For example, a same-site check when handling a `MessageEvent.origin` is difficult to perform correctly today as it requires an understanding of the [Public Suffix List](https://publicsuffix.org/)/[registrable domains](https://url.spec.whatwg.org/#host-registrable-domain) which we expose to the platform only indirectly. With an object like the above, this comparison becomes trivial:

```javascript
const allowlist = [
  Origin.parse("https://trusted.example"),
  Origin.parse("https://another-brand.example"),
  Origin.parse("https://brandtube.example"),
  Origin.parse("https://partner.biz"),
  ...
];
window.addEventListener('message', e => {
  const sender = Origin.parse(e.origin);

  // Exit the handler early if the sender isn't same-site with any
  // origin in the allowlist. This is a substantially more complicated
  // operation in the status quo:
  if (!allowlist.some(origin => { return origin.isSameSite(sender); }) {
    return;
  
  // Otherwise, do exciting and potentially dangerous things!
});
```

### An `OriginPattern` Matcher

We could support more expressive comparisons than `isSameOrigin()` and `isSameSite()` allow by extending the concept of `URLPattern`. A more constrained version of that object could restrict the acceptable patterns to `protocol`, `hostname`, and `port`; and `test()`/`exec()` against an (serialized) `Origin`:

```javascript
let pattern = new OriginPattern({
  protocol: "https",
  hostname: "{:subdomain.}?example.com",
  port: "*"
});  // Equivalent to `new OriginPattern("https://{*.}?example.com:*");`

pattern.test(Origin.parse("https://example.com"));            // true!
pattern.test(Origin.parse("https://sub.example.com"));        // true!
pattern.test(Origin.parse("https://sub.example.com:123"));    // true!
pattern.test(Origin.parse("https://subsub.sub.example.com")); // false!

// Invalid OriginPatterns:
try {
  pattern = new OriginPattern("https://user:pass@bad.example/path/to/something");
} catch (e) {
  // TypeError
}
```

Really, the only salient distinctions between `OriginPattern` and `URLPattern` are the name (which is important!) and the constructors, which would ignore members of `URLPatternInit` other than `protocol`, `hostname`, and `port`; and throw a `TypeError` for string inputs that contained constraints beyond those three aspects. This should make the implementation fairly trivial, while providing developers more clarity in their usage.

## Design Considerations

### Are origin checks enough?

Generally speaking, I think developers need to be able to correctly perform same-origin and same-site checks against origins they come into contact with through a number of existing APIs' `.origin` getters which return serialized strings. Given the difficulty of polyfilling those checks correctly, and the breadth of serialized origins' exposure, this seems like a necessary, but probably not sufficient, addition to the platform.

In some contexts, it makes sense to guide developers towards a broader spectrum of data. Handling `postMessage()` is a pretty good example of a situation in which it might make sense for developers to look not only at the incoming message's sender's origin, but also at other aspects of the sender's context. For example, we've gated `SameSite` cookies not only on a match between the sender and recipient origins, but also on the sender's ancestor chain. It might be reasonable to extend `MessageEvent` with some of this data, and it might be valuable to craft an API whose shape forces developers to think more holistically about how they handle incoming requests.


### Perhaps we could allow more direct conversion from URLs?

It's somewhat non-intuitive that an `Origin` representing `https://ümlauted.example` needs to be parsed as `https://xn--mlauted-m2a.example` due to the requirement to serialize IDNs using ASCII. We could simplify this for developers by either loosening our parser to handle things like Punycode in the same way URL does, or allow `Origin` objects to be constructed from `URL` objects (either directly as in `new Origin(url)`, or by introducing a conversion method like `Origin.fromURL()` or `URL.toOrigin()`).


### Should we expose the protocol, host, and port?

While the `Origin` object would likely hold a protocol, host, and port internally, it doesn't seem initially necessary to expose those on the object. This encourages developers to treat it as a single entity against which comparisons can be made, more clearly matching the underlying boundaries the object represents.


### What about "same origin-domain" checks?

Tuple origins are indeed a tuple consisting of scheme, host, port, and domain. If developers choose to use `document.domain`, then it might be possible to produce two `Origin` objects which would be "[same origin](https://html.spec.whatwg.org/multipage/browsers.html#same-origin)" but not "[same origin-domain](https://html.spec.whatwg.org/multipage/browsers.html#same-origin-domain)".

Insofar as we've done our best to collectively deprecate `document.domain`, and we've chosen to elide the domain from the origin's serialization today, I'd be perfectly happy omitting support for this check from the set we offer to developers. Still, probably worth considering this as an issue to explicitly decide upon.


### What about "schemelessly same site" checks?

Likewise, I'd be perfectly comfortable omitting [schemelessly same site](https://html.spec.whatwg.org/multipage/browsers.html#schemelessly-same-site) checks from the `Origin` object directly, though it's likely a reasonable thing to support via an explicitly-created `OriginPattern` (e.g. `new OriginPattern("*://example.site:*")`).

The [`URLHost` proposal](https://github.com/whatwg/url/pull/288) could also support this kind of check, perhaps even more straightforwardly.


### What about non-standard origin schemes certain UAs support?

User agents have minted a number of protocol-specific origin rules to support a variety of things (`chrome-extension`, `moz-extension`, `safari-web-extension`, etc) that violate the [origin of a URL](https://url.spec.whatwg.org/#concept-url-origin) steps by supporting non-opaque origins. It likely makes sense to shift the URL standard a bit to make room for these willful violations.


### Can we ship a global named `Origin`?

Idunno. Let's find out if it's already been widely stomped upon? If not, surely we can come up with some creative alternative.


### What about existing `.origin` getters?

It seems ideal to me for us to find ways to vend `Origin` objects rather than serialized origins whenever possible. It would likely be difficult to change the types of existing `.origin` attributes (though some use cases could be solved through the magic of stringification if we added it) though, and could create some confusing situations if older APIs rely on serialized origins while newer APIs vend `Origin` objects.

Still, working with `Origin` objects would make it possible to reason about opaque origins in ways which are impossible today. Since every opaque origin serializes as `"null"`, it's quite difficult to distinguish one from the other. While it would be nice to [mitigate that underlying issue](https://github.com/whatwg/html/issues/3585), opaque `Origin` objects the browser minted would at least allow for `isSameOrigin()` comparisons that developers could use to establish a sender's consistency over time, and more clarity around `postMessage()` targeting.

### What's this about opaque origins?

[Opaque origins](https://html.spec.whatwg.org/#concept-origin-opaque) are unique, matching no origin but themselves. Developers come across them frequently due either to loading resources that themselves have an opaque origin (e.g. `file:` or `data:` resources), or loading resources in a context that forces them into an opaque origin (e.g. `<iframe sandbox>` or `Content-Security-Policy: sandbox`).

For better or worse, these opaque origins serialize lossily to the same string, "`null`". So, while two distinct `<iframe sandbox></iframe>`s in a given document would have _distinct_ opaque origins, messages from those frames would both have a `MessageEvent.origin` of "`null`", which is unfortunate. Likewise, a single `<iframe sandbox></iframe>` that's navigated between messages would be impossible to identify from the origin serialization alone.

This (along with other esoteric properties of sandboxing) can lead to some unexpected interactions when performing origin checks, as demonstrated in a recent [CTF challenge](https://so-xss.terjanq.me/) ([writeup](https://github.com/terjanq/same-origin-xss#soxss---writeup)). Though the origins at play were in fact distinct, "`null`" unfortunately is strictly equal to "`null`". The origin confusion relied upon in that demonstration would have been handled correctly if `window.origin.isSameOrigin(event.origin)` had been available.

Likewise, enhancing `postMessage()` so that it would be possible to target messages to opaque origins with something other than "`*`". This could help developers ensure their target's consistency over time, for example by storing an incoming `MessageEvent.origin`, and using it rather than a string to target the `postMessage()`.

### What would this look like in IDL?

Maybe something like the following:

```javascript
//
// Origin
//
[Exposed=*]
interface Origin {
  constructor();
  constructor(USVString serializedOrigin);

  static Origin? parse(USVString serializedOrigin);
  static Origin? fromURL(USVString serializedURL);

  boolean isSameOrigin(Origin other);
  boolean isSameSite(Origin other);
};

//
// OriginPattern
//
[Exposed=(Window,Worker)]
interface OriginPattern : URLPattern {
  // Nothing? I think we'd really just want to replicate `URLPattern`
  // entirely, replacing the input parser with one that ignored all
  // members of `URLPatternInit` other than `protocol`, `hostname`,
  // and `port`; and/or threw a `TypeError` if a string input
  // contained anything beyond those three properties.
  // 
  // I think the rest of the object's behavior would fall out of
  // those restrictions on its input.
};
```
