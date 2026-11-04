defmodule Ankole.Plugins.LarkAdapter.Toolkits.Approvals do
  @moduledoc "Explicit lark_approvals Toolkit contracts, based on the Lark OpenAPI SDK models."
  alias Ankole.Connectors.ToolSpec

  @contracts Torque.decode!(~S"""
             [
               {
                 "name": "approvals_get_definition",
                 "description": "Approvals get definition.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "approval_code": {
                       "type": "string"
                     },
                     "locale": {
                       "type": "string"
                     },
                     "with_admin_id": {
                       "type": "boolean"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "with_option": {
                       "type": "boolean"
                     },
                     "user_id": {
                       "type": "string"
                     },
                     "nested_mutable_group": {
                       "type": "boolean"
                     }
                   },
                   "required": [
                     "approval_code"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "approval_name": {
                       "type": "string"
                     },
                     "status": {
                       "type": "string"
                     },
                     "form": {
                       "oneOf": [
                         {
                           "type": "string"
                         },
                         {
                           "type": "object"
                         },
                         {
                           "type": "array",
                           "items": {
                             "type": "object"
                           }
                         }
                       ]
                     },
                     "node_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "name": {
                             "type": "string"
                           },
                           "need_approver": {
                             "type": "boolean"
                           },
                           "node_id": {
                             "type": "string"
                           },
                           "custom_node_id": {
                             "type": "string"
                           },
                           "node_type": {
                             "type": "string"
                           },
                           "approver_chosen_multi": {
                             "type": "boolean"
                           },
                           "approver_chosen_range": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "approver_range_type": {
                                   "type": "integer"
                                 },
                                 "approver_range_ids": {
                                   "type": "array",
                                   "items": {
                                     "type": "string"
                                   }
                                 }
                               }
                             }
                           },
                           "require_signature": {
                             "type": "boolean"
                           }
                         }
                       }
                     },
                     "viewers": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "type": {
                             "type": "string"
                           },
                           "id": {
                             "type": "string"
                           },
                           "user_id": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "approval_admin_ids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "form_widget_relation": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/approval/v4/approvals/:approval_code",
                   "query": [
                     "locale",
                     "with_admin_id",
                     "user_id_type",
                     "with_option",
                     "user_id",
                     "nested_mutable_group"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "approval:approval:readonly"
                 ]
               },
               {
                 "name": "approvals_create_instance",
                 "description": "Approvals create instance.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "approval_code": {
                       "type": "string"
                     },
                     "department_id": {
                       "type": "string"
                     },
                     "form": {
                       "oneOf": [
                         {
                           "type": "array",
                           "items": {
                             "type": "object"
                           }
                         },
                         {
                           "type": "object"
                         }
                       ]
                     },
                     "node_approver_user_id_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "key": {
                             "type": "string"
                           },
                           "value": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           }
                         }
                       }
                     },
                     "node_approver_open_id_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "key": {
                             "type": "string"
                           },
                           "value": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           }
                         }
                       }
                     },
                     "node_cc_user_id_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "key": {
                             "type": "string"
                           },
                           "value": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           }
                         }
                       }
                     },
                     "node_cc_open_id_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "key": {
                             "type": "string"
                           },
                           "value": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           }
                         }
                       }
                     },
                     "uuid": {
                       "type": "string"
                     },
                     "allow_resubmit": {
                       "type": "boolean"
                     },
                     "allow_submit_again": {
                       "type": "boolean"
                     },
                     "cancel_bot_notification": {
                       "type": "string"
                     },
                     "forbid_revoke": {
                       "type": "boolean"
                     },
                     "i18n_resources": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "locale": {
                             "type": "string"
                           },
                           "texts": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "key": {
                                   "type": "string"
                                 },
                                 "value": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "is_default": {
                             "type": "boolean"
                           }
                         }
                       }
                     },
                     "title": {
                       "type": "string"
                     },
                     "title_display_method": {
                       "type": "integer"
                     },
                     "node_auto_approval_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "node_id_type": {
                             "type": "string"
                           },
                           "node_id": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "byte_extra": {
                       "type": "string"
                     },
                     "with_link": {
                       "type": "boolean"
                     }
                   },
                   "required": [
                     "approval_code",
                     "form",
                     "uuid"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "instance_code": {
                       "type": "string"
                     },
                     "instance_link": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/instances",
                   "query": []
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": true,
                 "destructive": true,
                 "scopes": [
                   "approval:approval"
                 ]
               },
               {
                 "name": "approvals_list_instances",
                 "description": "Approvals list instances.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "approval_code": {
                       "type": "string"
                     },
                     "start_time": {
                       "type": "string"
                     },
                     "end_time": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "approval_code",
                     "start_time",
                     "end_time"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "instance_code_list": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "has_more": {
                       "type": "boolean"
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/approval/v4/instances",
                   "query": [
                     "page_size",
                     "page_token",
                     "approval_code",
                     "start_time",
                     "end_time"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "approval:approval:readonly"
                 ]
               },
               {
                 "name": "approvals_get_instance",
                 "description": "Approvals get instance.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "instance_id": {
                       "type": "string"
                     },
                     "locale": {
                       "type": "string"
                     },
                     "user_id": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     },
                     "nested_mutable_group": {
                       "type": "boolean"
                     }
                   },
                   "required": [
                     "instance_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "approval_name": {
                       "type": "string"
                     },
                     "start_time": {
                       "type": "string"
                     },
                     "end_time": {
                       "type": "string"
                     },
                     "user_id": {
                       "type": "string"
                     },
                     "open_id": {
                       "type": "string"
                     },
                     "serial_number": {
                       "type": "string"
                     },
                     "department_id": {
                       "type": "string"
                     },
                     "status": {
                       "type": "string"
                     },
                     "uuid": {
                       "type": "string"
                     },
                     "form": {
                       "oneOf": [
                         {
                           "type": "string"
                         },
                         {
                           "type": "object"
                         },
                         {
                           "type": "array",
                           "items": {
                             "type": "object"
                           }
                         }
                       ]
                     },
                     "task_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "user_id": {
                             "type": "string"
                           },
                           "open_id": {
                             "type": "string"
                           },
                           "status": {
                             "type": "string"
                           },
                           "node_id": {
                             "type": "string"
                           },
                           "node_name": {
                             "type": "string"
                           },
                           "custom_node_id": {
                             "type": "string"
                           },
                           "type": {
                             "type": "string"
                           },
                           "start_time": {
                             "type": "string"
                           },
                           "end_time": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "comment_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "user_id": {
                             "type": "string"
                           },
                           "open_id": {
                             "type": "string"
                           },
                           "comment": {
                             "type": "string"
                           },
                           "create_time": {
                             "type": "string"
                           },
                           "files": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "file_size": {
                                   "type": "integer"
                                 },
                                 "title": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 }
                               }
                             }
                           }
                         }
                       }
                     },
                     "timeline": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "type": {
                             "type": "string"
                           },
                           "create_time": {
                             "type": "string"
                           },
                           "user_id": {
                             "type": "string"
                           },
                           "open_id": {
                             "type": "string"
                           },
                           "user_id_list": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "open_id_list": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "task_id": {
                             "type": "string"
                           },
                           "comment": {
                             "type": "string"
                           },
                           "cc_user_list": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "user_id": {
                                   "type": "string"
                                 },
                                 "cc_id": {
                                   "type": "string"
                                 },
                                 "open_id": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "ext": {
                             "type": "string"
                           },
                           "node_key": {
                             "type": "string"
                           },
                           "files": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "url": {
                                   "type": "string"
                                 },
                                 "file_size": {
                                   "type": "integer"
                                 },
                                 "title": {
                                   "type": "string"
                                 },
                                 "type": {
                                   "type": "string"
                                 }
                               }
                             }
                           }
                         }
                       }
                     },
                     "modified_instance_code": {
                       "type": "string"
                     },
                     "reverted_instance_code": {
                       "type": "string"
                     },
                     "approval_code": {
                       "type": "string"
                     },
                     "reverted": {
                       "type": "boolean"
                     },
                     "instance_code": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/approval/v4/instances/:instance_id",
                   "query": [
                     "locale",
                     "user_id",
                     "user_id_type",
                     "nested_mutable_group"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "approval:approval:readonly"
                 ]
               },
               {
                 "name": "approvals_list_tasks",
                 "description": "Approvals list tasks.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "page_size": {
                       "type": "integer"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "user_id": {
                       "type": "string"
                     },
                     "topic": {
                       "type": "string"
                     },
                     "user_id_type": {
                       "type": "string",
                       "enum": [
                         "user_id"
                       ]
                     }
                   },
                   "required": ["topic"],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "tasks": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "topic": {
                             "type": "string"
                           },
                           "user_id": {
                             "type": "string"
                           },
                           "title": {
                             "type": "string"
                           },
                           "urls": {
                             "type": "object",
                             "properties": {
                               "helpdesk": {
                                 "type": "string"
                               },
                               "mobile": {
                                 "type": "string"
                               },
                               "pc": {
                                 "type": "string"
                               }
                             }
                           },
                           "process_external_id": {
                             "type": "string"
                           },
                           "task_external_id": {
                             "type": "string"
                           },
                           "status": {
                             "type": "string"
                           },
                           "process_status": {
                             "type": "string"
                           },
                           "definition_code": {
                             "type": "string"
                           },
                           "initiators": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "initiator_names": {
                             "type": "array",
                             "items": {
                               "type": "string"
                             }
                           },
                           "task_id": {
                             "type": "string"
                           },
                           "process_id": {
                             "type": "string"
                           },
                           "process_code": {
                             "type": "string"
                           },
                           "definition_group_id": {
                             "type": "string"
                           },
                           "definition_group_name": {
                             "type": "string"
                           },
                           "definition_id": {
                             "type": "string"
                           },
                           "definition_name": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "has_more": {
                       "type": "boolean"
                     },
                     "count": {
                       "type": "object",
                       "properties": {
                         "total": {
                           "type": "integer"
                         },
                         "has_more": {
                           "type": "boolean"
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/approval/v4/tasks/query",
                   "query": [
                     "page_size",
                     "page_token",
                     "user_id",
                     "topic",
                     "user_id_type"
                   ]
                 },
                 "bound": false,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "approval:task:list_by_user"
                 ]
               },
               {
                 "name": "approvals_approve",
                 "description": "Approvals approve.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "approval_code": {
                       "type": "string"
                     },
                     "instance_code": {
                       "type": "string"
                     },
                     "comment": {
                       "type": "string"
                     },
                     "task_id": {
                       "type": "string"
                     },
                     "form": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "approval_code",
                     "instance_code",
                     "task_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/tasks/approve",
                   "query": []
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "approval:approval"
                 ]
               },
               {
                 "name": "approvals_reject",
                 "description": "Approvals reject.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "approval_code": {
                       "type": "string"
                     },
                     "instance_code": {
                       "type": "string"
                     },
                     "comment": {
                       "type": "string"
                     },
                     "task_id": {
                       "type": "string"
                     },
                     "form": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "approval_code",
                     "instance_code",
                     "task_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/tasks/reject",
                   "query": []
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "approval:approval"
                 ]
               },
               {
                 "name": "approvals_transfer",
                 "description": "Approvals transfer.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "approval_code": {
                       "type": "string"
                     },
                     "instance_code": {
                       "type": "string"
                     },
                     "comment": {
                       "type": "string"
                     },
                     "transfer_user_id": {
                       "type": "string"
                     },
                     "task_id": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "approval_code",
                     "instance_code",
                     "task_id",
                     "transfer_user_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/tasks/transfer",
                   "query": []
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "approval:approval"
                 ]
               },
               {
                 "name": "approvals_add_sign",
                 "description": "Approvals add sign.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "instance_code": {
                       "type": "string"
                     },
                     "task_id": {
                       "type": "string"
                     },
                     "comment": {
                       "type": "string"
                     },
                     "add_sign_user_ids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "add_sign_type": {
                       "type": "integer"
                     },
                     "approval_method": {
                       "type": "integer"
                     }
                   },
                   "required": [
                     "instance_code",
                     "task_id",
                     "add_sign_user_ids",
                     "add_sign_type"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/tasks/add_sign",
                   "query": []
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "user_oauth": true,
                 "scopes": [
                   "approval:task"
                 ]
               },
               {
                 "name": "approvals_rollback",
                 "description": "Approvals rollback.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "instance_code": {
                       "type": "string"
                     },
                     "task_id": {
                       "type": "string"
                     },
                     "comment": {
                       "type": "string"
                     },
                     "node_ids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     }
                   },
                   "required": [
                     "instance_code",
                     "task_id",
                     "node_ids"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/tasks/rollback",
                   "query": []
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "user_oauth": true,
                 "scopes": [
                   "approval:task"
                 ]
               },
               {
                 "name": "approvals_cancel",
                 "description": "Approvals cancel.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "approval_code": {
                       "type": "string"
                     },
                     "instance_code": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "approval_code",
                     "instance_code"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/instances/cancel",
                   "query": []
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "approval:approval"
                 ]
               },
               {
                 "name": "approvals_cc",
                 "description": "Approvals cc.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "approval_code": {
                       "type": "string"
                     },
                     "instance_code": {
                       "type": "string"
                     },
                     "cc_user_ids": {
                       "type": "array",
                       "items": {
                         "type": "string"
                       }
                     },
                     "comment": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "instance_code",
                     "cc_user_ids"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {}
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/instances/cc",
                   "query": []
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "approval:approval"
                 ]
               },
               {
                 "name": "approvals_list_comments",
                 "description": "Approvals list comments.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "instance_id": {
                       "type": "string"
                     },
                     "page_token": {
                       "type": "string"
                     },
                     "page_size": {
                       "type": "integer"
                     }
                   },
                   "required": [
                     "instance_id"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "comments": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "id": {
                             "type": "string"
                           },
                           "content": {
                             "type": "string"
                           },
                           "create_time": {
                             "type": "string"
                           },
                           "update_time": {
                             "type": "string"
                           },
                           "is_delete": {
                             "type": "integer"
                           },
                           "replies": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "id": {
                                   "type": "string"
                                 },
                                 "content": {
                                   "type": "string"
                                 },
                                 "create_time": {
                                   "type": "string"
                                 },
                                 "update_time": {
                                   "type": "string"
                                 },
                                 "is_delete": {
                                   "type": "integer"
                                 },
                                 "at_info_list": {
                                   "type": "array",
                                   "items": {
                                     "type": "object",
                                     "properties": {}
                                   }
                                 },
                                 "commentator": {
                                   "type": "string"
                                 },
                                 "extra": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "at_info_list": {
                             "type": "array",
                             "items": {
                               "type": "object",
                               "properties": {
                                 "user_id": {
                                   "type": "string"
                                 },
                                 "name": {
                                   "type": "string"
                                 },
                                 "offset": {
                                   "type": "string"
                                 }
                               }
                             }
                           },
                           "commentator": {
                             "type": "string"
                           },
                           "extra": {
                             "type": "string"
                           }
                         }
                       }
                     }
                   }
                 },
                 "operation": {
                   "method": "GET",
                   "path": "/open-apis/approval/v4/instances/:instance_id/comments",
                   "query": [
                     "user_id",
                     "page_token",
                     "page_size"
                   ]
                 },
                 "bound": true,
                 "read_only": true,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "approval:approval:readonly"
                 ]
               },
               {
                 "name": "approvals_create_comment",
                 "description": "Approvals create comment.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "instance_id": {
                       "type": "string"
                     },
                     "content": {
                       "type": "string"
                     },
                     "at_info_list": {
                       "type": "array",
                       "items": {
                         "type": "object",
                         "properties": {
                           "user_id": {
                             "type": "string"
                           },
                           "name": {
                             "type": "string"
                           },
                           "offset": {
                             "type": "string"
                           }
                         }
                       }
                     },
                     "parent_comment_id": {
                       "type": "string"
                     },
                     "comment_id": {
                       "type": "string"
                     },
                     "disable_bot": {
                       "type": "boolean"
                     },
                     "extra": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "instance_id",
                     "content"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "comment_id": {
                       "type": "string"
                     }
                   }
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/instances/:instance_id/comments",
                   "query": [
                     "user_id"
                   ]
                 },
                 "bound": true,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": true,
                 "scopes": [
                   "approval:approval"
                 ]
               },
               {
                 "name": "approvals_upload_file",
                 "description": "Upload an approval attachment from a Pod file.",
                 "input_schema": {
                   "type": "object",
                   "properties": {
                     "file_ref": {
                       "type": "string"
                     },
                     "name": {
                       "type": "string"
                     },
                     "type": {
                       "type": "string",
                       "enum": [
                         "image",
                         "attachment"
                       ]
                     }
                   },
                   "required": [
                     "file_ref",
                     "name",
                     "type"
                   ],
                   "additionalProperties": false
                 },
                 "output_schema": {
                   "type": "object",
                   "properties": {
                     "file_code": {
                       "type": "string"
                     }
                   },
                   "required": [
                     "file_code"
                   ]
                 },
                 "operation": {
                   "method": "POST",
                   "path": "/open-apis/approval/v4/files/upload",
                   "query": []
                 },
                 "bound": false,
                 "read_only": false,
                 "idempotent": false,
                 "destructive": false,
                 "scopes": [
                   "approval:approval"
                 ]
               }
             ]
             """)
  def tools do
    Enum.map(@contracts, fn contract ->
      %ToolSpec{
        toolkit: "lark_approvals",
        name: contract["name"],
        description: contract["description"],
        input_schema: contract["input_schema"],
        output_schema: contract["output_schema"],
        operation: contract["operation"],
        subject_policy:
          if(contract["bound"],
            do: :human_authority,
            else: :any_principal
          ),
        upstream_auth: auth(contract),
        scopes: contract["scopes"],
        annotations:
          ToolSpec.annotations(
            contract["read_only"],
            contract["idempotent"],
            contract["destructive"]
          )
      }
    end)
  end

  defp auth(%{"user_oauth" => true}), do: :human_oauth_token
  defp auth(%{"bound" => true}), do: :app_token_with_bound_user
  defp auth(%{"name" => "approvals_upload_file"}), do: :app_token
  defp auth(%{"name" => "approvals_list_tasks"}), do: :adaptive_token
  defp auth(_), do: :app_token
end
