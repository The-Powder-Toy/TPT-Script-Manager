# TPT Script Manager Server

## API

Unless otherwise specified, the response body of all endpoints is a JSON object,
and they all treat bad parameters as errors. Bad parameters generate response
objects of the form

 - `Status` is `"BadRequest"` (HTTP 400);
 - `Reason`: some machine-reachable explanation of the issue, e.g. `BadVersion`
   when a malformed version is passed to `PUT /staff/scripts/{Name}/Approved`.

### Authorization

Unless otherwise specified, all endpoints are subject to authorization.

Endpoints that are subject to authorization require the `X-ExternalAuth` request
header to be set to a valid ExternalAuth token with an Audience property of
`Script Manager` (or `Script Manager Testing` in test setups) (ask staff
members for details). Requests with this header missing or present but malformed
generate response objects of the forms

 - `Status` is `"BadRequest"` (HTTP 400);
 - `Reason` is `"NoXExternalAuth"`

and

 - `Status` is `"BadRequest"` (HTTP 400);
 - `Reason` is `"MalformedToken"`.

Requests with this header present and not malformed may still fail if the
backend refuses the token with response objects of the form

 - `Status` is `"BadRequest"` (HTTP 400);
 - `Reason` is `"BadToken"`;
 - `BackendStatus`: the backend's reason for not accepting the token,

or if the backend is down, with response objects of the form

 - `Status` is `"BadGateway"` (HTTP 502);
 - `Reason` is `"BackendFailure"`.

`/staff`-based endpoints report failure if the authorized user is not a
staff member. Such requests generate response objects of the form

 - `Status` is `"Forbidden"` (HTTP 403);
 - `Reason` is `"NotStaff"`.

### Rate limiting

Unless otherwise specified, all endpoints are subject to rate limiting.

Endpoints subject to rate limiting share a per-user rate limiting bucket. These
endpoints always set the following response headers:

 - `X-RateLimit-Bucket`: the name of the bucket the request belongs to; since
   there is only one bucket for each user, this header always takes the value
   `per-user`;
 - `X-RateLimit-Limit`: the number of requests belonging to this bucket that
   can be made in a rate limiting cycle;
 - `X-RateLimit-Interval`: the length of the rate limiting cycle of this bucket
   in seconds;
 - `X-RateLimit-Remaining`: the number of requests belonging to this bucket that
   can be made in the current rate limiting cycle without triggering rate
   limiting;
 - `X-RateLimit-ResetIn`: the length of the remaining portion of the current
   rate limiting cycle of this bucket in seconds.

When rate limiting is triggered, it generates response objects of the form

 - `Status` is `"TooManyRequests"` (HTTP 429).

In this case, the `Retry-After` response header is present and authoritative.

Peers that trigger error conditions too often may get address-banned. Such error
conditions are detectable by fail2ban or similar by looking for log patterns of
the form:

```
[record_failure from 93.184.216.34]
```

The IP addresses are taken as is from nginx, see `ip_address_method` in
config.lua.

Error conditions include, among other things:

 - rate limiting violations;
 - bad requests;
 - attempting to change scripts owned by someone else;
 - failing to authorize a user.

### `GET /data/manifest.json`

The response body is the manifest of available scripts in the form of a JSON
array whose items are objects with the following properties:

 - `Tag`: the unique identifier in string form of the script, can be used for
   tracking (unlike `Module`, which may change or be reclaimed upon deletion);
 - `Blob`: the blob in string form the script bundle is available under, see
   `GET /data/{Blob}`;
 - `CreatedAt`: seconds since Unix epoch at the point in time when the script
   was created in number form;
 - `UpdatedAt`: seconds since Unix epoch at the point in time when the script
   was last updated in number form;
 - `Module`: script name string;
 - `Title`: script title string;
 - `Description`: script description string;
 - `Listed`: a boolean, indicating whether the script should show up in search
   results (this has no effect on whether it is available for download, it is
   only a hint to the client);
 - `Version`: script version integer;
 - `StaffApproved`: Approved property in boolean form;
 - `Author`: script author's name (this can change, and even be stale;
   not reliable for identification);
 - `AuthorID`: script author's authentication backend ID (this cannot change,
   reliable for identification).

This endpoint is not subject to authorization or rate limiting.

### `GET /data/{Blob}`

The response body is a script bundle corresponding to `Blob` with a content
type of `application/x-gtar`. Parse the manifest for available bundles.

This endpoint is not subject to authorization or rate limiting.

### `PUT /scripts/{Name}`

The request body is a form with the following properties:

 - `Title`: desired script title;
 - `Description`: desired script description;
 - `Data`: desired script data; this is absolutely not verified for correctness
   or even format, that is the client's responsibility.

The response body is a JSON object with the following properties:

 - `Status`: request status, one of:
	- `"Forbidden"` (HTTP 403) if the authorized user is not allowed to make
	  changes to the script `Name` (staff members can work around this by
	  setting the `X-BypassOwnerCheck` request header to anything other than the
	  empty string), see the `Reason` response object property;
	- `"Conflict"` (HTTP 409) in the unlikely scenario in which a staff member
	  deletes the authorized user's record while the request is being processed;
	  in this case, the `Retry-After` response header is present and
	  authoritative;
	- `"BadRequest"` (HTTP 400) for the usual reasons, but also some
	  format-related reasons, see the `Reason` response object property;
	- `"OK"` (HTTP 200) upon success.
 - `Reason` (conditional): present if `Status` is `"BadRequest"`, in which
   case it explains the nature of the issue; beyond the standard reasons this
   status, this can be one of:
	- `"TooManyScripts"` if authorized user would have too many scripts if this
	  request were to succeed (see the `MaxScripts` user property);
	- `"TooMuchScriptData"` if authorized user would have too much script data
	  if this request were to succeed (see the `MaxScriptBytes` user
	  property);
	- `"ModuleLength"` if `Name` is longer than 100 bytes,
	  or is the empty string;
	- `"ModuleFormat"` if `Name` does not match the regular expression
	  `[a-zA-Z_][a-zA-Z_0-9]*` (standard identifier syntax);
	- `"TitleLength"` if the `Title` form parameter is longer than 100
	  bytes, or is the empty string;
	- `"DescriptionLength"` if the `Description` form parameter is longer than
	  500 bytes, or is the empty string;
   also present if `Status` is `"Forbidden"`, in which case it elaborates on the
   nature of the issue, this can be one of:
	- `"NoAccess"` the authorized user is not the owner of the script `Name`;
	- `"UserLocked"` the authorized user's account is locked;
 - `ActionTaken` (conditional): only present if `Status` is `"OK"`, in which
   case it is one of:
	- `"Created"`: if the script had had no earlier version and has just been
	  created;
	- `"Updated"`: if the script had had an earlier version and has just been
	  updated.

### `DELETE /scripts/{Name}`

The response body is a JSON object with the following properties:

 - `Status`: request status, one of:
	- `"Forbidden"` (HTTP 403) if the authorized user is not allowed to make
	  changes to the script `Name` (staff members can work around this by
	  setting the `X-BypassOwnerCheck` request header to anything other than the
	  empty string), see the `Reason` response object property;
	- `"Conflict"` (HTTP 409) in the unlikely scenario in which a staff member
	  deletes the authorized user's record while the request is being processed;
	  in this case, the `Retry-After` response header is present and
	  authoritative;
	- `"OK"` (HTTP 200) upon success.
 - `Reason` (conditional): only present if `Status` is `"Forbidden"`, in which
   case it elaborates on the nature of the issue, this can be one of:
	- `"NoAccess"` the authorized user is not the owner of the script `Name`;
	- `"UserLocked"` the authorized user's account is locked;
 - `ActionTaken` (conditional): only present if `Status` is `"OK"`, in which
   case it is one of:
	- `"Deleted"`: the script has just been deleted (this property takes this
	  value even if it had not existed).

### `PUT /staff/scripts/{Name}/Approved`

The request body is a form with the following properties:

 - `Approved`: the desired boolean `Approved` setting for the script `Name` in
   string form (`true` or `false`);
 - `Version`: the version of script `Name` whose `Approved` setting is to
   be modified; required only if `Approved` is `true`.

The response body is a JSON object with the following properties:

 - `Status`: request status, one of:
	- `"NotFound"` (HTTP 404) if the version `version` of script `Name` does not
	  exist;
	- `"OK"` (HTTP 200) upon success.

### `PUT /staff/users/{PowderID}/MaxScripts`

The request body is a form with the following properties:

 - `MaxScripts`: the desired integer `MaxScripts` setting for the user
   `PowderID` in string form.

The response body is a JSON object with the following properties:

 - `Status`: request status, one of:
	- `"Conflict"` (HTTP 409) upon a conflict with existing script data;
	- `"NotFound"` (HTTP 404) if user `PowderID` has not registered;
	- `"OK"` (HTTP 200) upon success.
 - `Reason` (conditional): only present if `Status` is `"Conflict"`, in which
   case it explains the nature of the conflict; one of:
   	- `"TooManyScripts"`: if the user has too many scripts for this setting to
   	  be successfully applied; try deleting a few scripts.

### `PUT /staff/users/{PowderID}/MaxScriptBytes`

The request body is a form with the following properties:

 - `MaxScriptBytes`: the desired integer `MaxScriptBytes` setting for the user
   `PowderID` in string form.

The response body is a JSON object with the following properties:

 - `Status`: request status, one of:
	- `"Conflict"` (HTTP 409) upon a conflict with existing script data;
	- `"NotFound"` (HTTP 404) if user `PowderID` has not registered;
	- `"OK"` (HTTP 200) upon success.
 - `Reason` (conditional): only present if `Status` is `"Conflict"`, in which
   case it explains the nature of the conflict; one of:
   	- `"TooMuchScriptData"`: if the user has too much script data for this
   	  setting to be successfully applied; try deleting a few scripts.

### `PUT /staff/users/{PowderID}/Locked`

The request body is a form with the following properties:

 - `Locked`: the desired boolean `Locked` setting for the user
   `powder_id` in string form (`true` or `false`).

The response body is a JSON object with the following properties:

 - `Status`: request status, one of:
	- `"NotFound"` (HTTP 404) if user `powder_id` has not registered;
	- `"OK"` (HTTP 200) upon success.
