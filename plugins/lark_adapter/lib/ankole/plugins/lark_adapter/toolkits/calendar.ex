defmodule Ankole.Plugins.LarkAdapter.Toolkits.Calendar do
  @moduledoc "Explicit lark_calendar Toolkit contracts, based on the Lark OpenAPI SDK models."
  alias Ankole.Connectors.ToolSpec

  @contracts Torque.decode!(~S"""
             [
               {
                 "name": "calendar_get_primary",
                 "description": "Calendar get primary.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "op_user_id": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "calendars": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "calendar": {
                             "type": "object",
                             "properties": {
                               "calendar_id": {
                                 "type": "string"
                               },
                               "summary": {
                                 "type": "string"
                               },
                               "description": {
                                 "type": "string"
                               },
                               "permissions": {
                                 "type": "string"
                               },
                               "color": {
                                 "type": "integer"
                               },
                               "type": {
                                 "type": "string"
                               },
                               "summary_alias": {
                                 "type": "string"
                               },
                               "is_deleted": {
                                 "type": "boolean"
                               },
                               "is_third_party": {
                                 "type": "boolean"
                               },
                               "role": {
                                 "type": "string"
                               }
                             }
                           },
                           "user_id": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/calendar/v4/calendars/primary",
                   "query": [
                     "user_id_type",
                     "op_user_id"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar:read"
                 ]
               },
               {
                 "name": "calendar_list",
                 "description": "Calendar list.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "sync_token": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "has_more": {
                       "type": "boolean"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "sync_token": {
                       "type": "string"
                     },
                     "calendar_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "calendar_id": {
                             "type": "string"
                           },
                           "summary": {
                             "type": "string"
                           },
                           "description": {
                             "type": "string"
                           },
                           "permissions": {
                             "type": "string"
                           },
                           "color": {
                             "type": "integer"
                           },
                           "type": {
                             "type": "string"
                           },
                           "summary_alias": {
                             "type": "string"
                           },
                           "is_deleted": {
                             "type": "boolean"
                           },
                           "is_third_party": {
                             "type": "boolean"
                           },
                           "role": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/calendar/v4/calendars",
                   "query": [
                     "page_size",
                     "page_token",
                     "sync_token"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar:read"
                 ]
               },
               {
                 "name": "calendar_create_shared",
                 "description": "Calendar create shared.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "summary": {
                       "type": "string"
                     },
                     "description": {
                       "type": "string"
                     },
                     "permissions": {
                       "type": "string"
                     },
                     "color": {
                       "type": "integer"
                     },
                     "type": {
                       "type": "string"
                     },
                     "summary_alias": {
                       "type": "string"
                     },
                     "is_deleted": {
                       "type": "boolean"
                     },
                     "is_third_party": {
                       "type": "boolean"
                     },
                     "role": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "summary"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "calendar": {
                       "type": "object",
                       "properties": {
                         "calendar_id": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "permissions": {
                           "type": "string"
                         },
                         "color": {
                           "type": "integer"
                         },
                         "type": {
                           "type": "string"
                         },
                         "summary_alias": {
                           "type": "string"
                         },
                         "is_deleted": {
                           "type": "boolean"
                         },
                         "is_third_party": {
                           "type": "boolean"
                         },
                         "role": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/calendar/v4/calendars",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar:create"
                 ]
               },
               {
                 "name": "calendar_query_freebusy",
                 "description": "Calendar query freebusy.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "time_min": {
                       "type": "string"
                     },
                     "time_max": {
                       "type": "string"
                     },
                     "user_ids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "include_external_calendar": {
                       "type": "boolean"
                     },
                     "only_busy": {
                       "type": "boolean"
                     },
                     "need_rsvp_status": {
                       "type": "boolean"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     },
                     "principal_uids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     }
                   },
                   "required": [
                     "time_min",
                     "time_max"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "freebusy_lists": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "freebusy_items": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "start_time": {
                                   "type": "string"
                                 },
                                 "end_time": {
                                   "type": "string"
                                 },
                                 "rsvp_status": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "user_id": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/calendar/v4/freebusy/batch",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.free_busy:read"
                 ]
               },
               {
                 "name": "calendar_create_event",
                 "description": "Calendar create event.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "idempotency_key": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "event_id": {
                       "type": "string"
                     },
                     "organizer_calendar_id": {
                       "type": "string"
                     },
                     "summary": {
                       "type": "string"
                     },
                     "description": {
                       "type": "string"
                     },
                     "need_notification": {
                       "type": "boolean"
                     },
                     "start_time": {
                       "oneOf": [
                         {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         {
                           "type": "string",
                           "format": "date-time"
                         }
                       ]
                     },
                     "end_time": {
                       "oneOf": [
                         {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         {
                           "type": "string",
                           "format": "date-time"
                         }
                       ]
                     },
                     "vchat": {
                       "type": "object",
                       "properties": {
                         "vc_type": {
                           "type": "string"
                         },
                         "icon_type": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "meeting_url": {
                           "type": "string"
                         },
                         "live_link": {
                           "type": "string"
                         },
                         "vc_info": {
                           "type": "object",
                           "properties": {
                             "unique_id": {
                               "type": "string"
                             },
                             "meeting_no": {
                               "type": "string"
                             }
                           }
                         },
                         "meeting_settings": {
                           "type": "object",
                           "properties": {
                             "owner_id": {
                               "type": "string"
                             },
                             "join_meeting_permission": {
                               "type": "string"
                             },
                             "password": {
                               "type": "string"
                             },
                             "assign_hosts": {
                               "type": "array",
                               "items": {
                                 "type": "string"
                               }
                             },
                             "auto_record": {
                               "type": "boolean"
                             },
                             "open_lobby": {
                               "type": "boolean"
                             },
                             "allow_attendees_start": {
                               "type": "boolean"
                             }
                           }
                         },
                         "third_party_meeting_settings": {
                           "type": "object",
                           "properties": {
                             "meeting_type": {
                               "type": "string"
                             },
                             "meeting_id": {
                               "type": "string"
                             },
                             "meeting_no": {
                               "type": "string"
                             },
                             "password": {
                               "type": "string"
                             },
                             "meeting_descriptions": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "lang": {
                                     "type": "string"
                                   },
                                   "description": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         }
                       }
                     },
                     "visibility": {
                       "type": "string"
                     },
                     "attendee_ability": {
                       "type": "string"
                     },
                     "free_busy_status": {
                       "type": "string"
                     },
                     "location": {
                       "type": "object",
                       "properties": {
                         "name": {
                           "type": "string"
                         },
                         "address": {
                           "type": "string"
                         },
                         "latitude": {
                           "type": "number"
                         },
                         "longitude": {
                           "type": "number"
                         }
                       }
                     },
                     "color": {
                       "type": "integer"
                     },
                     "reminders": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "minutes": {
                             "type": "integer"
                           }
                         }
                       }
                     },
                     "recurrence": {
                       "type": "string"
                     },
                     "status": {
                       "type": "string"
                     },
                     "is_exception": {
                       "type": "boolean"
                     },
                     "recurring_event_id": {
                       "type": "string"
                     },
                     "create_time": {
                       "type": "string"
                     },
                     "schemas": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "ui_name": {
                             "type": "string"
                           },
                           "ui_status": {
                             "type": "string"
                           },
                           "app_link": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "event_organizer": {
                       "type": "object",
                       "properties": {
                         "user_id": {
                           "type": "string"
                         },
                         "display_name": {
                           "type": "string"
                         }
                       }
                     },
                     "app_link": {
                       "type": "string"
                     },
                     "attendees": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "type": {
                             "type": "string"
                           },
                           "attendee_id": {
                             "type": "string"
                           },
                           "rsvp_status": {
                             "type": "string"
                           },
                           "is_optional": {
                             "type": "boolean"
                           },
                           "is_organizer": {
                             "type": "boolean"
                           },
                           "is_external": {
                             "type": "boolean"
                           },
                           "display_name": {
                             "type": "string"
                           },
                           "chat_members": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "rsvp_status": {
                                   "type": "string"
                                 },
                                 "is_optional": {
                                   "type": "boolean"
                                 },
                                 "display_name": {
                                   "type": "string"
                                 },
                                 "is_organizer": {
                                   "type": "boolean"
                                 },
                                 "is_external": {
                                   "type": "boolean"
                                 }
                               }
                             }
                           },
                           "user_id": {
                             "type": "string"
                           },
                           "chat_id": {
                             "type": "string"
                           },
                           "room_id": {
                             "type": "string"
                           },
                           "third_party_email": {
                             "type": "string"
                           },
                           "operate_id": {
                             "type": "string"
                           },
                           "resource_customization": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "index_key": {
                                   "type": "string"
                                 },
                                 "input_content": {
                                   "type": "string"
                                 },
                                 "options": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {
                                       "option_key": {
                                         "type": "string"
                                       },
                                       "others_content": {
                                         "type": "string"
                                       }
                                     }
                                   }
                                 }
                               }
                             }
                           },
                           "approval_reason": {
                             "type": "string"
                           },
                           "principal_uid": {
                             "type": "string",
                             "description": "Ankole human UID; resolves the verified Lark employee identity and sets type=user."
                           }
                         }
                       }
                     },
                     "has_more_attendee": {
                       "type": "boolean"
                     },
                     "attachments": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "file_token": {
                             "type": "string"
                           },
                           "file_size": {
                             "type": "string"
                           },
                           "is_deleted": {
                             "type": "boolean"
                           },
                           "name": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "event_check_in": {
                       "type": "object",
                       "properties": {
                         "enable_check_in": {
                           "type": "boolean"
                         },
                         "check_in_start_time": {
                           "type": "object",
                           "properties": {
                             "time_type": {
                               "type": "string"
                             },
                             "duration": {
                               "type": "integer"
                             }
                           }
                         },
                         "check_in_end_time": {
                           "type": "object",
                           "properties": {
                             "time_type": {
                               "type": "string"
                             },
                             "duration": {
                               "type": "integer"
                             }
                           }
                         },
                         "need_notify_attendees": {
                           "type": "boolean"
                         }
                       }
                     },
                     "source": {
                       "type": "string"
                     },
                     "self_rsvp_status": {
                       "type": "string"
                     },
                     "description_rich": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "summary",
                     "start_time",
                     "end_time"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "event": {
                       "type": "object",
                       "properties": {
                         "event_id": {
                           "type": "string"
                         },
                         "organizer_calendar_id": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "need_notification": {
                           "type": "boolean"
                         },
                         "start_time": {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         "end_time": {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         "vchat": {
                           "type": "object",
                           "properties": {
                             "vc_type": {
                               "type": "string"
                             },
                             "icon_type": {
                               "type": "string"
                             },
                             "description": {
                               "type": "string"
                             },
                             "meeting_url": {
                               "type": "string"
                             },
                             "live_link": {
                               "type": "string"
                             },
                             "vc_info": {
                               "type": "object",
                               "properties": {
                                 "unique_id": {
                                   "type": "string"
                                 },
                                 "meeting_no": {
                                   "type": "string"
                                 }
                               }
                             },
                             "meeting_settings": {
                               "type": "object",
                               "properties": {
                                 "owner_id": {
                                   "type": "string"
                                 },
                                 "join_meeting_permission": {
                                   "type": "string"
                                 },
                                 "password": {
                                   "type": "string"
                                 },
                                 "assign_hosts": {
                                   "type": "array",
                                   "items": {
                                     "type": "string"
                                   }
                                 },
                                 "auto_record": {
                                   "type": "boolean"
                                 },
                                 "open_lobby": {
                                   "type": "boolean"
                                 },
                                 "allow_attendees_start": {
                                   "type": "boolean"
                                 }
                               }
                             },
                             "third_party_meeting_settings": {
                               "type": "object",
                               "properties": {
                                 "meeting_type": {
                                   "type": "string"
                                 },
                                 "meeting_id": {
                                   "type": "string"
                                 },
                                 "meeting_no": {
                                   "type": "string"
                                 },
                                 "password": {
                                   "type": "string"
                                 },
                                 "meeting_descriptions": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "visibility": {
                           "type": "string"
                         },
                         "attendee_ability": {
                           "type": "string"
                         },
                         "free_busy_status": {
                           "type": "string"
                         },
                         "location": {
                           "type": "object",
                           "properties": {
                             "name": {
                               "type": "string"
                             },
                             "address": {
                               "type": "string"
                             },
                             "latitude": {
                               "type": "number"
                             },
                             "longitude": {
                               "type": "number"
                             }
                           }
                         },
                         "color": {
                           "type": "integer"
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "minutes": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "recurrence": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "is_exception": {
                           "type": "boolean"
                         },
                         "recurring_event_id": {
                           "type": "string"
                         },
                         "create_time": {
                           "type": "string"
                         },
                         "schemas": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "ui_name": {
                                 "type": "string"
                               },
                               "ui_status": {
                                 "type": "string"
                               },
                               "app_link": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "event_organizer": {
                           "type": "object",
                           "properties": {
                             "user_id": {
                               "type": "string"
                             },
                             "display_name": {
                               "type": "string"
                             }
                           }
                         },
                         "app_link": {
                           "type": "string"
                         },
                         "attendees": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "attendee_id": {
                                 "type": "string"
                               },
                               "rsvp_status": {
                                 "type": "string"
                               },
                               "is_optional": {
                                 "type": "boolean"
                               },
                               "is_organizer": {
                                 "type": "boolean"
                               },
                               "is_external": {
                                 "type": "boolean"
                               },
                               "display_name": {
                                 "type": "string"
                               },
                               "chat_members": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "user_id": {
                                 "type": "string"
                               },
                               "chat_id": {
                                 "type": "string"
                               },
                               "room_id": {
                                 "type": "string"
                               },
                               "third_party_email": {
                                 "type": "string"
                               },
                               "operate_id": {
                                 "type": "string"
                               },
                               "resource_customization": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "approval_reason": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "has_more_attendee": {
                           "type": "boolean"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "file_token": {
                                 "type": "string"
                               },
                               "file_size": {
                                 "type": "string"
                               },
                               "is_deleted": {
                                 "type": "boolean"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "event_check_in": {
                           "type": "object",
                           "properties": {
                             "enable_check_in": {
                               "type": "boolean"
                             },
                             "check_in_start_time": {
                               "type": "object",
                               "properties": {
                                 "time_type": {
                                   "type": "string"
                                 },
                                 "duration": {
                                   "type": "integer"
                                 }
                               }
                             },
                             "check_in_end_time": {
                               "type": "object",
                               "properties": {
                                 "time_type": {
                                   "type": "string"
                                 },
                                 "duration": {
                                   "type": "integer"
                                 }
                               }
                             },
                             "need_notify_attendees": {
                               "type": "boolean"
                             }
                           }
                         },
                         "source": {
                           "type": "string"
                         },
                         "self_rsvp_status": {
                           "type": "string"
                         },
                         "description_rich": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events",
                   "query": [
                     "idempotency_key",
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.event:create"
                 ]
               },
               {
                 "name": "calendar_patch_event",
                 "description": "Update event details. Use calendar_manage_attendees to add or remove attendees.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "event_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "organizer_calendar_id": {
                       "type": "string"
                     },
                     "summary": {
                       "type": "string"
                     },
                     "description": {
                       "type": "string"
                     },
                     "need_notification": {
                       "type": "boolean"
                     },
                     "start_time": {
                       "oneOf": [
                         {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         {
                           "type": "string",
                           "format": "date-time"
                         }
                       ]
                     },
                     "end_time": {
                       "oneOf": [
                         {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         {
                           "type": "string",
                           "format": "date-time"
                         }
                       ]
                     },
                     "vchat": {
                       "type": "object",
                       "properties": {
                         "vc_type": {
                           "type": "string"
                         },
                         "icon_type": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "meeting_url": {
                           "type": "string"
                         },
                         "live_link": {
                           "type": "string"
                         },
                         "vc_info": {
                           "type": "object",
                           "properties": {
                             "unique_id": {
                               "type": "string"
                             },
                             "meeting_no": {
                               "type": "string"
                             }
                           }
                         },
                         "meeting_settings": {
                           "type": "object",
                           "properties": {
                             "owner_id": {
                               "type": "string"
                             },
                             "join_meeting_permission": {
                               "type": "string"
                             },
                             "password": {
                               "type": "string"
                             },
                             "assign_hosts": {
                               "type": "array",
                               "items": {
                                 "type": "string"
                               }
                             },
                             "auto_record": {
                               "type": "boolean"
                             },
                             "open_lobby": {
                               "type": "boolean"
                             },
                             "allow_attendees_start": {
                               "type": "boolean"
                             }
                           }
                         },
                         "third_party_meeting_settings": {
                           "type": "object",
                           "properties": {
                             "meeting_type": {
                               "type": "string"
                             },
                             "meeting_id": {
                               "type": "string"
                             },
                             "meeting_no": {
                               "type": "string"
                             },
                             "password": {
                               "type": "string"
                             },
                             "meeting_descriptions": {
                               "type": "array",
                               "items": {
                                 "type": "object",
                                 "properties": {
                                   "lang": {
                                     "type": "string"
                                   },
                                   "description": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           }
                         }
                       }
                     },
                     "visibility": {
                       "type": "string"
                     },
                     "attendee_ability": {
                       "type": "string"
                     },
                     "free_busy_status": {
                       "type": "string"
                     },
                     "location": {
                       "type": "object",
                       "properties": {
                         "name": {
                           "type": "string"
                         },
                         "address": {
                           "type": "string"
                         },
                         "latitude": {
                           "type": "number"
                         },
                         "longitude": {
                           "type": "number"
                         }
                       }
                     },
                     "color": {
                       "type": "integer"
                     },
                     "reminders": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "minutes": {
                             "type": "integer"
                           }
                         }
                       }
                     },
                     "recurrence": {
                       "type": "string"
                     },
                     "status": {
                       "type": "string"
                     },
                     "is_exception": {
                       "type": "boolean"
                     },
                     "recurring_event_id": {
                       "type": "string"
                     },
                     "create_time": {
                       "type": "string"
                     },
                     "schemas": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "ui_name": {
                             "type": "string"
                           },
                           "ui_status": {
                             "type": "string"
                           },
                           "app_link": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "event_organizer": {
                       "type": "object",
                       "properties": {
                         "user_id": {
                           "type": "string"
                         },
                         "display_name": {
                           "type": "string"
                         }
                       }
                     },
                     "app_link": {
                       "type": "string"
                     },
                     "has_more_attendee": {
                       "type": "boolean"
                     },
                     "attachments": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "file_token": {
                             "type": "string"
                           },
                           "file_size": {
                             "type": "string"
                           },
                           "is_deleted": {
                             "type": "boolean"
                           },
                           "name": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "event_check_in": {
                       "type": "object",
                       "properties": {
                         "enable_check_in": {
                           "type": "boolean"
                         },
                         "check_in_start_time": {
                           "type": "object",
                           "properties": {
                             "time_type": {
                               "type": "string"
                             },
                             "duration": {
                               "type": "integer"
                             }
                           }
                         },
                         "check_in_end_time": {
                           "type": "object",
                           "properties": {
                             "time_type": {
                               "type": "string"
                             },
                             "duration": {
                               "type": "integer"
                             }
                           }
                         },
                         "need_notify_attendees": {
                           "type": "boolean"
                         }
                       }
                     },
                     "source": {
                       "type": "string"
                     },
                     "self_rsvp_status": {
                       "type": "string"
                     },
                     "description_rich": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "event_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "event": {
                       "type": "object",
                       "properties": {
                         "event_id": {
                           "type": "string"
                         },
                         "organizer_calendar_id": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "need_notification": {
                           "type": "boolean"
                         },
                         "start_time": {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         "end_time": {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         "vchat": {
                           "type": "object",
                           "properties": {
                             "vc_type": {
                               "type": "string"
                             },
                             "icon_type": {
                               "type": "string"
                             },
                             "description": {
                               "type": "string"
                             },
                             "meeting_url": {
                               "type": "string"
                             },
                             "live_link": {
                               "type": "string"
                             },
                             "vc_info": {
                               "type": "object",
                               "properties": {
                                 "unique_id": {
                                   "type": "string"
                                 },
                                 "meeting_no": {
                                   "type": "string"
                                 }
                               }
                             },
                             "meeting_settings": {
                               "type": "object",
                               "properties": {
                                 "owner_id": {
                                   "type": "string"
                                 },
                                 "join_meeting_permission": {
                                   "type": "string"
                                 },
                                 "password": {
                                   "type": "string"
                                 },
                                 "assign_hosts": {
                                   "type": "array",
                                   "items": {
                                     "type": "string"
                                   }
                                 },
                                 "auto_record": {
                                   "type": "boolean"
                                 },
                                 "open_lobby": {
                                   "type": "boolean"
                                 },
                                 "allow_attendees_start": {
                                   "type": "boolean"
                                 }
                               }
                             },
                             "third_party_meeting_settings": {
                               "type": "object",
                               "properties": {
                                 "meeting_type": {
                                   "type": "string"
                                 },
                                 "meeting_id": {
                                   "type": "string"
                                 },
                                 "meeting_no": {
                                   "type": "string"
                                 },
                                 "password": {
                                   "type": "string"
                                 },
                                 "meeting_descriptions": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "visibility": {
                           "type": "string"
                         },
                         "attendee_ability": {
                           "type": "string"
                         },
                         "free_busy_status": {
                           "type": "string"
                         },
                         "location": {
                           "type": "object",
                           "properties": {
                             "name": {
                               "type": "string"
                             },
                             "address": {
                               "type": "string"
                             },
                             "latitude": {
                               "type": "number"
                             },
                             "longitude": {
                               "type": "number"
                             }
                           }
                         },
                         "color": {
                           "type": "integer"
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "minutes": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "recurrence": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "is_exception": {
                           "type": "boolean"
                         },
                         "recurring_event_id": {
                           "type": "string"
                         },
                         "create_time": {
                           "type": "string"
                         },
                         "schemas": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "ui_name": {
                                 "type": "string"
                               },
                               "ui_status": {
                                 "type": "string"
                               },
                               "app_link": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "event_organizer": {
                           "type": "object",
                           "properties": {
                             "user_id": {
                               "type": "string"
                             },
                             "display_name": {
                               "type": "string"
                             }
                           }
                         },
                         "app_link": {
                           "type": "string"
                         },
                         "attendees": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "attendee_id": {
                                 "type": "string"
                               },
                               "rsvp_status": {
                                 "type": "string"
                               },
                               "is_optional": {
                                 "type": "boolean"
                               },
                               "is_organizer": {
                                 "type": "boolean"
                               },
                               "is_external": {
                                 "type": "boolean"
                               },
                               "display_name": {
                                 "type": "string"
                               },
                               "chat_members": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "user_id": {
                                 "type": "string"
                               },
                               "chat_id": {
                                 "type": "string"
                               },
                               "room_id": {
                                 "type": "string"
                               },
                               "third_party_email": {
                                 "type": "string"
                               },
                               "operate_id": {
                                 "type": "string"
                               },
                               "resource_customization": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "approval_reason": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "has_more_attendee": {
                           "type": "boolean"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "file_token": {
                                 "type": "string"
                               },
                               "file_size": {
                                 "type": "string"
                               },
                               "is_deleted": {
                                 "type": "boolean"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "event_check_in": {
                           "type": "object",
                           "properties": {
                             "enable_check_in": {
                               "type": "boolean"
                             },
                             "check_in_start_time": {
                               "type": "object",
                               "properties": {
                                 "time_type": {
                                   "type": "string"
                                 },
                                 "duration": {
                                   "type": "integer"
                                 }
                               }
                             },
                             "check_in_end_time": {
                               "type": "object",
                               "properties": {
                                 "time_type": {
                                   "type": "string"
                                 },
                                 "duration": {
                                   "type": "integer"
                                 }
                               }
                             },
                             "need_notify_attendees": {
                               "type": "boolean"
                             }
                           }
                         },
                         "source": {
                           "type": "string"
                         },
                         "self_rsvp_status": {
                           "type": "string"
                         },
                         "description_rich": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "PATCH",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events/:event_id",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.event:update"
                 ]
               },
               {
                 "name": "calendar_delete_event",
                 "description": "Calendar delete event.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "event_id": {
                       "type": "string"
                     },
                     "need_notification": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "event_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "DELETE",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events/:event_id",
                   "query": [
                     "need_notification"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "calendar:calendar.event:delete"
                 ]
               },
               {
                 "name": "calendar_get_event",
                 "description": "Calendar get event.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "event_id": {
                       "type": "string"
                     },
                     "need_meeting_settings": {
                       "type": "boolean"
                     },
                     "need_attendee": {
                       "type": "boolean"
                     },
                     "max_attendee_num": {
                       "type": "integer"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "op_user_id": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "event_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "event": {
                       "type": "object",
                       "properties": {
                         "event_id": {
                           "type": "string"
                         },
                         "organizer_calendar_id": {
                           "type": "string"
                         },
                         "summary": {
                           "type": "string"
                         },
                         "description": {
                           "type": "string"
                         },
                         "need_notification": {
                           "type": "boolean"
                         },
                         "start_time": {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         "end_time": {
                           "type": "object",
                           "properties": {
                             "date": {
                               "type": "string"
                             },
                             "date_time": {
                               "type": "string"
                             },
                             "timestamp": {
                               "type": "string"
                             },
                             "timezone": {
                               "type": "string"
                             }
                           }
                         },
                         "vchat": {
                           "type": "object",
                           "properties": {
                             "vc_type": {
                               "type": "string"
                             },
                             "icon_type": {
                               "type": "string"
                             },
                             "description": {
                               "type": "string"
                             },
                             "meeting_url": {
                               "type": "string"
                             },
                             "live_link": {
                               "type": "string"
                             },
                             "vc_info": {
                               "type": "object",
                               "properties": {
                                 "unique_id": {
                                   "type": "string"
                                 },
                                 "meeting_no": {
                                   "type": "string"
                                 }
                               }
                             },
                             "meeting_settings": {
                               "type": "object",
                               "properties": {
                                 "owner_id": {
                                   "type": "string"
                                 },
                                 "join_meeting_permission": {
                                   "type": "string"
                                 },
                                 "password": {
                                   "type": "string"
                                 },
                                 "assign_hosts": {
                                   "type": "array",
                                   "items": {
                                     "type": "string"
                                   }
                                 },
                                 "auto_record": {
                                   "type": "boolean"
                                 },
                                 "open_lobby": {
                                   "type": "boolean"
                                 },
                                 "allow_attendees_start": {
                                   "type": "boolean"
                                 }
                               }
                             },
                             "third_party_meeting_settings": {
                               "type": "object",
                               "properties": {
                                 "meeting_type": {
                                   "type": "string"
                                 },
                                 "meeting_id": {
                                   "type": "string"
                                 },
                                 "meeting_no": {
                                   "type": "string"
                                 },
                                 "password": {
                                   "type": "string"
                                 },
                                 "meeting_descriptions": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               }
                             }
                           }
                         },
                         "visibility": {
                           "type": "string"
                         },
                         "attendee_ability": {
                           "type": "string"
                         },
                         "free_busy_status": {
                           "type": "string"
                         },
                         "location": {
                           "type": "object",
                           "properties": {
                             "name": {
                               "type": "string"
                             },
                             "address": {
                               "type": "string"
                             },
                             "latitude": {
                               "type": "number"
                             },
                             "longitude": {
                               "type": "number"
                             }
                           }
                         },
                         "color": {
                           "type": "integer"
                         },
                         "reminders": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "minutes": {
                                 "type": "integer"
                               }
                             }
                           }
                         },
                         "recurrence": {
                           "type": "string"
                         },
                         "status": {
                           "type": "string"
                         },
                         "is_exception": {
                           "type": "boolean"
                         },
                         "recurring_event_id": {
                           "type": "string"
                         },
                         "create_time": {
                           "type": "string"
                         },
                         "schemas": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "ui_name": {
                                 "type": "string"
                               },
                               "ui_status": {
                                 "type": "string"
                               },
                               "app_link": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "event_organizer": {
                           "type": "object",
                           "properties": {
                             "user_id": {
                               "type": "string"
                             },
                             "display_name": {
                               "type": "string"
                             }
                           }
                         },
                         "app_link": {
                           "type": "string"
                         },
                         "attendees": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "type": {
                                 "type": "string"
                               },
                               "attendee_id": {
                                 "type": "string"
                               },
                               "rsvp_status": {
                                 "type": "string"
                               },
                               "is_optional": {
                                 "type": "boolean"
                               },
                               "is_organizer": {
                                 "type": "boolean"
                               },
                               "is_external": {
                                 "type": "boolean"
                               },
                               "display_name": {
                                 "type": "string"
                               },
                               "chat_members": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "user_id": {
                                 "type": "string"
                               },
                               "chat_id": {
                                 "type": "string"
                               },
                               "room_id": {
                                 "type": "string"
                               },
                               "third_party_email": {
                                 "type": "string"
                               },
                               "operate_id": {
                                 "type": "string"
                               },
                               "resource_customization": {
                                 "type": "array",
                                 "items": {
                                   "type": "object",
                                   "properties": {}
                                 }
                               },
                               "approval_reason": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "has_more_attendee": {
                           "type": "boolean"
                         },
                         "attachments": {
                           "type": "array",
                           "items": {
                             "type": "object",
                             "properties": {
                               "file_token": {
                                 "type": "string"
                               },
                               "file_size": {
                                 "type": "string"
                               },
                               "is_deleted": {
                                 "type": "boolean"
                               },
                               "name": {
                                 "type": "string"
                               }
                             }
                           }
                         },
                         "event_check_in": {
                           "type": "object",
                           "properties": {
                             "enable_check_in": {
                               "type": "boolean"
                             },
                             "check_in_start_time": {
                               "type": "object",
                               "properties": {
                                 "time_type": {
                                   "type": "string"
                                 },
                                 "duration": {
                                   "type": "integer"
                                 }
                               }
                             },
                             "check_in_end_time": {
                               "type": "object",
                               "properties": {
                                 "time_type": {
                                   "type": "string"
                                 },
                                 "duration": {
                                   "type": "integer"
                                 }
                               }
                             },
                             "need_notify_attendees": {
                               "type": "boolean"
                             }
                           }
                         },
                         "source": {
                           "type": "string"
                         },
                         "self_rsvp_status": {
                           "type": "string"
                         },
                         "description_rich": {
                           "type": "string"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events/:event_id",
                   "query": [
                     "need_meeting_settings",
                     "need_attendee",
                     "max_attendee_num",
                     "user_id_type",
                     "op_user_id"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.event:read"
                 ]
               },
               {
                 "name": "calendar_list_events",
                 "description": "Calendar list events.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     },
                     "anchor_time": {
                       "type": "string"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "sync_token": {
                       "type": "string"
                     },
                     "start_time": {
                       "type": "string"
                     },
                     "end_time": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "op_user_id": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "has_more": {
                       "type": "boolean"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "sync_token": {
                       "type": "string"
                     },
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "event_id": {
                             "type": "string"
                           },
                           "organizer_calendar_id": {
                             "type": "string"
                           },
                           "summary": {
                             "type": "string"
                           },
                           "description": {
                             "type": "string"
                           },
                           "need_notification": {
                             "type": "boolean"
                           },
                           "start_time": {
                             "type": "object",
                             "properties": {
                               "date": {
                                 "type": "string"
                               },
                               "date_time": {
                                 "type": "string"
                               },
                               "timestamp": {
                                 "type": "string"
                               },
                               "timezone": {
                                 "type": "string"
                               }
                             }
                           },
                           "end_time": {
                             "type": "object",
                             "properties": {
                               "date": {
                                 "type": "string"
                               },
                               "date_time": {
                                 "type": "string"
                               },
                               "timestamp": {
                                 "type": "string"
                               },
                               "timezone": {
                                 "type": "string"
                               }
                             }
                           },
                           "vchat": {
                             "type": "object",
                             "properties": {
                               "vc_type": {
                                 "type": "string"
                               },
                               "icon_type": {
                                 "type": "string"
                               },
                               "description": {
                                 "type": "string"
                               },
                               "meeting_url": {
                                 "type": "string"
                               },
                               "live_link": {
                                 "type": "string"
                               },
                               "vc_info": {
                                 "type": "object",
                                 "properties": {
                                   "unique_id": {
                                     "type": "string"
                                   },
                                   "meeting_no": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "meeting_settings": {
                                 "type": "object",
                                 "properties": {
                                   "owner_id": {
                                     "type": "string"
                                   },
                                   "join_meeting_permission": {
                                     "type": "string"
                                   },
                                   "password": {
                                     "type": "string"
                                   },
                                   "assign_hosts": {
                                     "type": "array",
                                     "items": {
                                       "type": "string"
                                     }
                                   },
                                   "auto_record": {
                                     "type": "boolean"
                                   },
                                   "open_lobby": {
                                     "type": "boolean"
                                   },
                                   "allow_attendees_start": {
                                     "type": "boolean"
                                   }
                                 }
                               },
                               "third_party_meeting_settings": {
                                 "type": "object",
                                 "properties": {
                                   "meeting_type": {
                                     "type": "string"
                                   },
                                   "meeting_id": {
                                     "type": "string"
                                   },
                                   "meeting_no": {
                                     "type": "string"
                                   },
                                   "password": {
                                     "type": "string"
                                   },
                                   "meeting_descriptions": {
                                     "type": "array",
                                     "items": {
                                       "type": "object",
                                       "properties": {}
                                     }
                                   }
                                 }
                               }
                             }
                           },
                           "visibility": {
                             "type": "string"
                           },
                           "attendee_ability": {
                             "type": "string"
                           },
                           "free_busy_status": {
                             "type": "string"
                           },
                           "location": {
                             "type": "object",
                             "properties": {
                               "name": {
                                 "type": "string"
                               },
                               "address": {
                                 "type": "string"
                               },
                               "latitude": {
                                 "type": "number"
                               },
                               "longitude": {
                                 "type": "number"
                               }
                             }
                           },
                           "color": {
                             "type": "integer"
                           },
                           "reminders": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "minutes": {
                                   "type": "integer"
                                 }
                               }
                             }
                           },
                           "recurrence": {
                             "type": "string"
                           },
                           "status": {
                             "type": "string"
                           },
                           "is_exception": {
                             "type": "boolean"
                           },
                           "recurring_event_id": {
                             "type": "string"
                           },
                           "create_time": {
                             "type": "string"
                           },
                           "schemas": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "ui_name": {
                                   "type": "string"
                                 },
                                 "ui_status": {
                                   "type": "string"
                                 },
                                 "app_link": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "event_organizer": {
                             "type": "object",
                             "properties": {
                               "user_id": {
                                 "type": "string"
                               },
                               "display_name": {
                                 "type": "string"
                               }
                             }
                           },
                           "app_link": {
                             "type": "string"
                           },
                           "attendees": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "type": {
                                   "type": "string"
                                 },
                                 "attendee_id": {
                                   "type": "string"
                                 },
                                 "rsvp_status": {
                                   "type": "string"
                                 },
                                 "is_optional": {
                                   "type": "boolean"
                                 },
                                 "is_organizer": {
                                   "type": "boolean"
                                 },
                                 "is_external": {
                                   "type": "boolean"
                                 },
                                 "display_name": {
                                   "type": "string"
                                 },
                                 "chat_members": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 },
                                 "user_id": {
                                   "type": "string"
                                 },
                                 "chat_id": {
                                   "type": "string"
                                 },
                                 "room_id": {
                                   "type": "string"
                                 },
                                 "third_party_email": {
                                   "type": "string"
                                 },
                                 "operate_id": {
                                   "type": "string"
                                 },
                                 "resource_customization": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 },
                                 "approval_reason": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "has_more_attendee": {
                             "type": "boolean"
                           },
                           "attachments": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "file_token": {
                                   "type": "string"
                                 },
                                 "file_size": {
                                   "type": "string"
                                 },
                                 "is_deleted": {
                                   "type": "boolean"
                                 },
                                 "name": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "event_check_in": {
                             "type": "object",
                             "properties": {
                               "enable_check_in": {
                                 "type": "boolean"
                               },
                               "check_in_start_time": {
                                 "type": "object",
                                 "properties": {
                                   "time_type": {
                                     "type": "string"
                                   },
                                   "duration": {
                                     "type": "integer"
                                   }
                                 }
                               },
                               "check_in_end_time": {
                                 "type": "object",
                                 "properties": {
                                   "time_type": {
                                     "type": "string"
                                   },
                                   "duration": {
                                     "type": "integer"
                                   }
                                 }
                               },
                               "need_notify_attendees": {
                                 "type": "boolean"
                               }
                             }
                           },
                           "source": {
                             "type": "string"
                           },
                           "self_rsvp_status": {
                             "type": "string"
                           },
                           "description_rich": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events",
                   "query": [
                     "page_size",
                     "anchor_time",
                     "page_token",
                     "sync_token",
                     "start_time",
                     "end_time",
                     "user_id_type",
                     "op_user_id"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.event:read"
                 ]
               },
               {
                 "name": "calendar_search_events",
                 "description": "Calendar search events.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     },
                     "query": {
                       "type": "string"
                     },
                     "filter": {
                       "type": "object",
                       "properties": {
                         "start_time": {
                           "oneOf": [
                             {
                               "type": "object",
                               "properties": {
                                 "date": {
                                   "type": "string"
                                 },
                                 "date_time": {
                                   "type": "string"
                                 },
                                 "timestamp": {
                                   "type": "string"
                                 },
                                 "timezone": {
                                   "type": "string"
                                 }
                               }
                             },
                             {
                               "type": "string",
                               "format": "date-time"
                             }
                           ]
                         },
                         "end_time": {
                           "oneOf": [
                             {
                               "type": "object",
                               "properties": {
                                 "date": {
                                   "type": "string"
                                 },
                                 "date_time": {
                                   "type": "string"
                                 },
                                 "timestamp": {
                                   "type": "string"
                                 },
                                 "timezone": {
                                   "type": "string"
                                 }
                               }
                             },
                             {
                               "type": "string",
                               "format": "date-time"
                             }
                           ]
                         },
                         "user_ids": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "room_ids": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         },
                         "chat_ids": {
                           "type": "array",
                           "items": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "query"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "event_id": {
                             "type": "string"
                           },
                           "organizer_calendar_id": {
                             "type": "string"
                           },
                           "summary": {
                             "type": "string"
                           },
                           "description": {
                             "type": "string"
                           },
                           "need_notification": {
                             "type": "boolean"
                           },
                           "start_time": {
                             "type": "object",
                             "properties": {
                               "date": {
                                 "type": "string"
                               },
                               "date_time": {
                                 "type": "string"
                               },
                               "timestamp": {
                                 "type": "string"
                               },
                               "timezone": {
                                 "type": "string"
                               }
                             }
                           },
                           "end_time": {
                             "type": "object",
                             "properties": {
                               "date": {
                                 "type": "string"
                               },
                               "date_time": {
                                 "type": "string"
                               },
                               "timestamp": {
                                 "type": "string"
                               },
                               "timezone": {
                                 "type": "string"
                               }
                             }
                           },
                           "vchat": {
                             "type": "object",
                             "properties": {
                               "vc_type": {
                                 "type": "string"
                               },
                               "icon_type": {
                                 "type": "string"
                               },
                               "description": {
                                 "type": "string"
                               },
                               "meeting_url": {
                                 "type": "string"
                               },
                               "live_link": {
                                 "type": "string"
                               },
                               "vc_info": {
                                 "type": "object",
                                 "properties": {
                                   "unique_id": {
                                     "type": "string"
                                   },
                                   "meeting_no": {
                                     "type": "string"
                                   }
                                 }
                               },
                               "meeting_settings": {
                                 "type": "object",
                                 "properties": {
                                   "owner_id": {
                                     "type": "string"
                                   },
                                   "join_meeting_permission": {
                                     "type": "string"
                                   },
                                   "password": {
                                     "type": "string"
                                   },
                                   "assign_hosts": {
                                     "type": "array",
                                     "items": {
                                       "type": "string"
                                     }
                                   },
                                   "auto_record": {
                                     "type": "boolean"
                                   },
                                   "open_lobby": {
                                     "type": "boolean"
                                   },
                                   "allow_attendees_start": {
                                     "type": "boolean"
                                   }
                                 }
                               },
                               "third_party_meeting_settings": {
                                 "type": "object",
                                 "properties": {
                                   "meeting_type": {
                                     "type": "string"
                                   },
                                   "meeting_id": {
                                     "type": "string"
                                   },
                                   "meeting_no": {
                                     "type": "string"
                                   },
                                   "password": {
                                     "type": "string"
                                   },
                                   "meeting_descriptions": {
                                     "type": "array",
                                     "items": {
                                       "type": "object",
                                       "properties": {}
                                     }
                                   }
                                 }
                               }
                             }
                           },
                           "visibility": {
                             "type": "string"
                           },
                           "attendee_ability": {
                             "type": "string"
                           },
                           "free_busy_status": {
                             "type": "string"
                           },
                           "location": {
                             "type": "object",
                             "properties": {
                               "name": {
                                 "type": "string"
                               },
                               "address": {
                                 "type": "string"
                               },
                               "latitude": {
                                 "type": "number"
                               },
                               "longitude": {
                                 "type": "number"
                               }
                             }
                           },
                           "color": {
                             "type": "integer"
                           },
                           "reminders": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "minutes": {
                                   "type": "integer"
                                 }
                               }
                             }
                           },
                           "recurrence": {
                             "type": "string"
                           },
                           "status": {
                             "type": "string"
                           },
                           "is_exception": {
                             "type": "boolean"
                           },
                           "recurring_event_id": {
                             "type": "string"
                           },
                           "create_time": {
                             "type": "string"
                           },
                           "schemas": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "ui_name": {
                                   "type": "string"
                                 },
                                 "ui_status": {
                                   "type": "string"
                                 },
                                 "app_link": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "event_organizer": {
                             "type": "object",
                             "properties": {
                               "user_id": {
                                 "type": "string"
                               },
                               "display_name": {
                                 "type": "string"
                               }
                             }
                           },
                           "app_link": {
                             "type": "string"
                           },
                           "attendees": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "type": {
                                   "type": "string"
                                 },
                                 "attendee_id": {
                                   "type": "string"
                                 },
                                 "rsvp_status": {
                                   "type": "string"
                                 },
                                 "is_optional": {
                                   "type": "boolean"
                                 },
                                 "is_organizer": {
                                   "type": "boolean"
                                 },
                                 "is_external": {
                                   "type": "boolean"
                                 },
                                 "display_name": {
                                   "type": "string"
                                 },
                                 "chat_members": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 },
                                 "user_id": {
                                   "type": "string"
                                 },
                                 "chat_id": {
                                   "type": "string"
                                 },
                                 "room_id": {
                                   "type": "string"
                                 },
                                 "third_party_email": {
                                   "type": "string"
                                 },
                                 "operate_id": {
                                   "type": "string"
                                 },
                                 "resource_customization": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 },
                                 "approval_reason": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "has_more_attendee": {
                             "type": "boolean"
                           },
                           "attachments": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "file_token": {
                                   "type": "string"
                                 },
                                 "file_size": {
                                   "type": "string"
                                 },
                                 "is_deleted": {
                                   "type": "boolean"
                                 },
                                 "name": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "event_check_in": {
                             "type": "object",
                             "properties": {
                               "enable_check_in": {
                                 "type": "boolean"
                               },
                               "check_in_start_time": {
                                 "type": "object",
                                 "properties": {
                                   "time_type": {
                                     "type": "string"
                                   },
                                   "duration": {
                                     "type": "integer"
                                   }
                                 }
                               },
                               "check_in_end_time": {
                                 "type": "object",
                                 "properties": {
                                   "time_type": {
                                     "type": "string"
                                   },
                                   "duration": {
                                     "type": "integer"
                                   }
                                 }
                               },
                               "need_notify_attendees": {
                                 "type": "boolean"
                               }
                             }
                           },
                           "source": {
                             "type": "string"
                           },
                           "self_rsvp_status": {
                             "type": "string"
                           },
                           "description_rich": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "page_token": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events/search",
                   "query": [
                     "user_id_type",
                     "page_token",
                     "page_size"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.event:read"
                 ]
               },
               {
                 "name": "calendar_list_attendees",
                 "description": "Calendar list attendees.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "event_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "need_resource_customization": {
                       "type": "boolean"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     },
                     "op_user_id": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "event_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "items": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "type": {
                             "type": "string"
                           },
                           "attendee_id": {
                             "type": "string"
                           },
                           "rsvp_status": {
                             "type": "string"
                           },
                           "is_optional": {
                             "type": "boolean"
                           },
                           "is_organizer": {
                             "type": "boolean"
                           },
                           "is_external": {
                             "type": "boolean"
                           },
                           "display_name": {
                             "type": "string"
                           },
                           "chat_members": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "rsvp_status": {
                                   "type": "string"
                                 },
                                 "is_optional": {
                                   "type": "boolean"
                                 },
                                 "display_name": {
                                   "type": "string"
                                 },
                                 "is_organizer": {
                                   "type": "boolean"
                                 },
                                 "is_external": {
                                   "type": "boolean"
                                 }
                               }
                             }
                           },
                           "user_id": {
                             "type": "string"
                           },
                           "chat_id": {
                             "type": "string"
                           },
                           "room_id": {
                             "type": "string"
                           },
                           "third_party_email": {
                             "type": "string"
                           },
                           "operate_id": {
                             "type": "string"
                           },
                           "resource_customization": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "index_key": {
                                   "type": "string"
                                 },
                                 "input_content": {
                                   "type": "string"
                                 },
                                 "options": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               }
                             }
                           },
                           "approval_reason": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "has_more": {
                       "type": "boolean"
                     },
                     "page_token": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events/:event_id/attendees",
                   "query": [
                     "user_id_type",
                     "need_resource_customization",
                     "page_token",
                     "page_size",
                     "op_user_id"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.event:read"
                 ]
               },
               {
                 "name": "calendar_manage_attendees",
                 "description": "Calendar manage attendees.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "event_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "attendees": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "type": {
                             "type": "string"
                           },
                           "attendee_id": {
                             "type": "string"
                           },
                           "rsvp_status": {
                             "type": "string"
                           },
                           "is_optional": {
                             "type": "boolean"
                           },
                           "is_organizer": {
                             "type": "boolean"
                           },
                           "is_external": {
                             "type": "boolean"
                           },
                           "display_name": {
                             "type": "string"
                           },
                           "chat_members": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "rsvp_status": {
                                   "type": "string"
                                 },
                                 "is_optional": {
                                   "type": "boolean"
                                 },
                                 "display_name": {
                                   "type": "string"
                                 },
                                 "is_organizer": {
                                   "type": "boolean"
                                 },
                                 "is_external": {
                                   "type": "boolean"
                                 }
                               }
                             }
                           },
                           "user_id": {
                             "type": "string"
                           },
                           "chat_id": {
                             "type": "string"
                           },
                           "room_id": {
                             "type": "string"
                           },
                           "third_party_email": {
                             "type": "string"
                           },
                           "operate_id": {
                             "type": "string"
                           },
                           "resource_customization": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "index_key": {
                                   "type": "string"
                                 },
                                 "input_content": {
                                   "type": "string"
                                 },
                                 "options": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               }
                             }
                           },
                           "approval_reason": {
                             "type": "string"
                           },
                           "principal_uid": {
                             "type": "string",
                             "description": "Ankole human UID; resolves the verified Lark employee identity and sets type=user."
                           }
                         }
                       }
                     },
                     "need_notification": {
                       "type": "boolean"
                     },
                     "instance_start_time_admin": {
                       "type": "string"
                     },
                     "is_enable_admin": {
                       "type": "boolean"
                     },
                     "add_operator_to_attendee": {
                       "type": "boolean"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     },
                     "operation": {
                       "type": "string",
                       "enum": [
                         "add",
                         "remove"
                       ]
                     },
                     "attendee_ids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     }
                   },
                   "required": [
                     "event_id",
                     "operation"
                   ],
                   "additionalProperties": false,
                   "anyOf": [
                     {
                       "properties": {
                         "operation": {
                           "const": "add"
                         }
                       },
                       "required": [
                         "attendees"
                       ]
                     },
                     {
                       "properties": {
                         "operation": {
                           "const": "remove"
                         }
                       },
                       "required": [
                         "attendee_ids"
                       ]
                     }
                   ]
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "attendees": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "type": {
                             "type": "string"
                           },
                           "attendee_id": {
                             "type": "string"
                           },
                           "rsvp_status": {
                             "type": "string"
                           },
                           "is_optional": {
                             "type": "boolean"
                           },
                           "is_organizer": {
                             "type": "boolean"
                           },
                           "is_external": {
                             "type": "boolean"
                           },
                           "display_name": {
                             "type": "string"
                           },
                           "chat_members": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "rsvp_status": {
                                   "type": "string"
                                 },
                                 "is_optional": {
                                   "type": "boolean"
                                 },
                                 "display_name": {
                                   "type": "string"
                                 },
                                 "is_organizer": {
                                   "type": "boolean"
                                 },
                                 "is_external": {
                                   "type": "boolean"
                                 }
                               }
                             }
                           },
                           "user_id": {
                             "type": "string"
                           },
                           "chat_id": {
                             "type": "string"
                           },
                           "room_id": {
                             "type": "string"
                           },
                           "third_party_email": {
                             "type": "string"
                           },
                           "operate_id": {
                             "type": "string"
                           },
                           "resource_customization": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "index_key": {
                                   "type": "string"
                                 },
                                 "input_content": {
                                   "type": "string"
                                 },
                                 "options": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 }
                               }
                             }
                           },
                           "approval_reason": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events/:event_id/attendees",
                   "query": [
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.event:update"
                 ]
               },
               {
                 "name": "calendar_reply_event",
                 "description": "Calendar reply event.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "calendar_id": {
                       "type": "string"
                     },
                     "event_id": {
                       "type": "string"
                     },
                     "rsvp_status": {
                       "type": "string"
                     },
                     "resource_scope": {
                       "type": "string",
                       "enum": [
                         "personal",
                         "app"
                       ]
                     }
                   },
                   "required": [
                     "event_id",
                     "rsvp_status"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/calendar/v4/calendars/:calendar_id/events/:event_id/reply",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "calendar:calendar.event:reply"
                 ]
               }
             ]
             """)
  @tools Enum.map(@contracts, fn contract ->
           personal? = contract["name"] == "calendar_reply_event"

           %ToolSpec{
             toolkit: "lark_calendar",
             name: contract["name"],
             description: contract["description"],
             input_schema: contract["input_schema"],
             output_schema: contract["output_schema"],
             operation: contract["operation"],
             subject_policy: if(personal?, do: :human_authority, else: :any_principal),
             upstream_auth: if(personal?, do: :human_oauth_token, else: :adaptive_token),
             scopes: contract["scopes"],
             annotations:
               ToolSpec.annotations(
                 contract["read_only"],
                 contract["idempotent"],
                 contract["destructive"]
               )
           }
           |> ToolSpec.compile()
         end)

  def tools, do: @tools
end
