/*
 * Copyright (C) 2016 "IoT.bzh"
 *
 * Author Romain Forlot <romain@iot.bzh>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <fapis.h>
#include <ctl-plugin.h>

struct fapisHandleT {
	AFB_ApiT mainApiHandle;
	CtlSectionT *section;
	json_object *fapiJ;
	json_object *verbsJ;
};

static int LoadOneFapi(void *data, AFB_ApiT apiHandle)
{
	struct fapisHandleT *fapisHandle = (struct fapisHandleT*)data;

	if(PluginConfig(apiHandle, fapisHandle->section, fapisHandle->fapiJ)) {
		AFB_ApiError(apiHandle, "Problem loading the plugin as an API for %s, see log message above", json_object_get_string(fapisHandle->fapiJ));
		return -1;
	}

	// declare the verbs for this API
	if(! ActionConfig(apiHandle, fapisHandle->verbsJ, 1)) {
		AFB_ApiError(apiHandle, "Problems at verbs creations for %s", json_object_get_string(fapisHandle->fapiJ));
		return -1;
	}
	// declare an event event manager for this API;
	afb_dynapi_on_event(apiHandle, CtrlDispatchApiEvent);

	return 0;
}

static void OneFapiConfig(void *data, json_object *fapiJ) {
	const char *uid = NULL, *info = NULL;

	struct fapisHandleT *fapisHandle = (struct fapisHandleT*)data;

	if(fapiJ) {
		if(wrap_json_unpack(fapiJ, "{ss,s?s,s?s,so,s?o,so !}",
					"uid", &uid,
					"info", &info,
					"spath", NULL,
					"libs", NULL,
					"lua", NULL,
					"verbs", &fapisHandle->verbsJ)) {
		AFB_ApiError(fapisHandle->mainApiHandle, "Wrong fapis specification, missing uid|[info]|[spath]|libs|[lua]|verbs");
		return;
		}

		json_object_get(fapisHandle->verbsJ);
		json_object_object_del(fapiJ, "verbs");
		fapisHandle->fapiJ = fapiJ;

		if (afb_dynapi_new_api(fapisHandle->mainApiHandle, uid, info, 1, LoadOneFapi, (void*)fapisHandle)) {
			AFB_ApiError(fapisHandle->mainApiHandle, "Error creating new api: %s", uid);
			return;
		}
	}
}

int FapisConfig(AFB_ApiT apiHandle, CtlSectionT *section, json_object *fapisJ) {
	struct fapisHandleT fapisHandle = {
		.mainApiHandle = apiHandle,
		.section = section,
		.fapiJ = NULL,
		.verbsJ = NULL
	};
	wrap_json_optarray_for_all(fapisJ, OneFapiConfig, (void*)&fapisHandle);

	return 0;
}
