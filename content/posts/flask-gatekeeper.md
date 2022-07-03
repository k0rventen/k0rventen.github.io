---
title: "Gatekeeper, a ban & rate limit lib for flask"
date: 2022-06-27
draft: false
description: "Avoid bursting and brute forcing on your flask app"
tags : ["python","flask","module"]
---

_Avoid bursting and brute forcing on your flask app, with RFC6585 compliance_

# what & why

Rate limiting is a powerful way to restrict the use of a given service by allowing a given rate of requests.
Banning on the other hand can be used to block malicious attacks, mainly brute forcing on authentification routes.

The Flask framework does not provide these functionnalities natively (which is normal, it's a WSGI app constructor) but we can create a module to perform these features through flask's primitives. 

The goal is to create a simple module that can:
  - rate limit all or any given subset of routes exposed by flask,
  - ban IPs based on their behavior,
  - support running behind a reverse proxy (when the client IP is the proxy's, and the real client IP is somewhere in the headers)


# how

Enter `Flask-gatekeeper`. It answers all the needs depicted above, but beware that it has some notable tradeoffs, mainly the fact that it's a stateless module.

Let's have a look on how to use the module. We'll first initialize it alongside our flask app:
```py
app = Flask(__name__)
gk = GateKeeper(app, # or use .init_app(app) later 
                ip_header="x-my-ip", # optionnal header to use for the client IP (e.g if using a reverse proxy)
                ban_rule={"count":3,"window":10,"duration":600}, # 3 reports in a 10s window will ban for 600s
                rate_limit_rules=[{"count":20,"window":1},{"count":100,"window":10}], # rate limiting will be applied if over 20 requests in 1s or 100 requests in 10s
                excluded_methods=["HEAD"]) # do not add HEAD requests to the tally 
```

The `GateKeeper` constructor takes somes self explanatory arguments that will configure the main instance. 
If running behind a reverse proxy, we can supply the header that will contain the IP of the og client (`X-Real-IP` if its Nginx for example)
All requests will be added to the tally per client, including HEAD or OPTIONS requests. We can ignore specific methods using the `excluded_methods` arg.


Then when we define routes, they will by default be subject to the rate limiting applied by the GateKeeper we defined above.

```py
@app.route("/ping") # this route is rate limited by the global rule
def ping():
    return "ok",200
```

If we do not want to apply any rate limiting on a givern route, we can decorate the route as such:
```py
@app.route("/bypass")
@gk.bypass # do not apply anything on that route
def bypass():
    return "ok",200
```

Some routes might need additional, stricter rate limiting. In this case, we can define new rate limiting rules to be added on top on the ones we defined above:

```py
@app.route("/global_plus_specific")
@gk.specific(rate_limit_rules=[{"count":1,"window":2}]) # add another rate limit on top of the global one (to avoid bursting for example)
def specific():
    return "ok",200
```

We might want specific rate limiting for specific routes, for example a broader rule:

```py
@app.route("/standalone")
@gk.specific(rate_limit_rules=[{"count":10,"window":3600}],standalone=True) # rate limited only by this rule
def standalone():
    return "ok",200
```


Finally, we can control when IPs are banned using the `.report()` method. 
A generic use case would be to report the IP if the authentification failed, and it will be banned whenever the number of tries surpasses our rule.
```py
@app.route("/login")
def login():
    if request.json.get("password") == "password":
        return token,200
    else:
        gk.report() # report the request's IP, after 3 reports in this case the IP will be banned 
        return "bad password",401
```

Let's launch our app and try a few endpoints to see how it works. Note that the shell being used is fish, and some outputs are truncated for readability.


```sh
for i in (seq 11)
  http get :5000/standalone
end

[...]

HTTP/1.1 429 TOO MANY REQUESTS
Connection: close
Content-Length: 72
Content-Type: text/html; charset=utf-8
Date: Mon, 27 Jun 2022 18:56:38 GMT
Retry-After: 3441
Server: Werkzeug/2.1.2 Python/3.10.4

ip 127.0.0.1 rate limited for 3441s (over 10 requests in a 3600s window)
```

When the rate limiting applies, as per the [RFC6585](https://datatracker.ietf.org/doc/html/rfc6585#section-4), a HTTP code 429 is returned, with the `Retry-After` header containing in seconds the time to wait, and a short explanation present in the body.


Now let's try the banning:
```sh
for i in (seq 4)
  http get :5000/login password=notthegoodpwd
end

HTTP/1.1 401 UNAUTHORIZED
Connection: close
Content-Length: 12
Content-Type: text/html; charset=utf-8
Date: Mon, 27 Jun 2022 19:02:31 GMT
Server: Werkzeug/2.1.2 Python/3.10.4

bad password

[...]

HTTP/1.1 403 FORBIDDEN
Connection: close
Content-Length: 63
Content-Type: text/html; charset=utf-8
Date: Mon, 27 Jun 2022 19:02:34 GMT
Retry-After: 596
Server: Werkzeug/2.1.2 Python/3.10.4

ip 127.0.0.1 banned for 596s (reported 3 times in a 10s window)
```

After 3 failed attempt, the default `401` reply is short-circuited by GateKeeper and a `403` is sent instead. As for the rate limiting, a short explanation is sent through the body, alongside a `Retry-After` header.



To give it a try or check the documentation, the module is available on [PyPi](https://pypi.org/project/flask-gatekeeper/), the code [here](https://github.com/k0rventen/flask-gatekeeper) on Github.