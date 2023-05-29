# frozen_string_literal: true

require_relative "ai/version"
require "tracer"
require "irb"
require "openai"
require "tty-markdown"

module IRB
  module AI
    def self.debug_mode?
      ENV["IRB_AI_DEBUG"] && !ENV["IRB_AI_DEBUG"].empty?
    end

    def self.ai_client
      @ai_client ||= OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
    end

    def self.register_irb_commands
      ec = IRB::ExtendCommandBundle.instance_variable_get(:@EXTEND_COMMANDS)

      [
        [
          :explain,
          :Explain,
          nil,
          [:explain, IRB::ExtendCommandBundle::OVERRIDE_ALL]
        ]
      ].each do |ecconfig|
        ec.push(ecconfig)
        IRB::ExtendCommandBundle.def_extend_command(*ecconfig)
      end
    end
  end

  module ExtendCommand
    class Explain < IRB::ExtendCommand::Nop
      IRB_PATH = Gem.loaded_specs["irb"].full_gem_path

      category "AI"
      description "WIP"

      def self.transform_args(args)
        # Return a string literal as is for backward compatibility
        if args.empty? || string_literal?(args)
          args
        else # Otherwise, consider the input as a String for convenience
          args.strip.dump
        end
      end

      def execute(*args)
        expression = args.first&.chomp

        unless expression
          puts "Please provide the expression to explain. Usage: `explain <expression>`"
          return
        end

        output = StringIO.new
        context_obj = irb_context.workspace.main
        exception = nil

        context_binding = irb_context.workspace.binding

        ObjectTracer
          .new(
            context_obj,
            output: output,
            colorize: false,
            header: "object-trace"
          )
          .start do
            ExceptionTracer
              .new(output: output, colorize: false, header: "exception-trace")
              .start do
                begin
                  eval(expression, context_binding)
                rescue Exception => e
                  exception = e
                end
              end
          end

        traces = output.string

        response =
          send_messages(
            expression: expression,
            context_binding: context_binding,
            context_obj: context_obj,
            traces: traces,
            exception: exception
          )

        if AI.debug_mode?
          puts "=== Raw Response ==="
          pp response
        end

        if error = response.dig("error", "message")
          if error.match?(/reduce the length/)
            puts "The generated request is too long. Trying again without runtimne traces..."
            response =
              send_messages(
                expression: expression,
                context_binding: context_binding,
                context_obj: context_obj,
                traces: "",
                exception: exception
              )
          else
            puts "OpenAI returned an error: #{error["message"]}"
            return
          end
        end

        finish_reason = response.dig("choices", 0, "finish_reason")

        case finish_reason
        when "stop"
        else
          puts "OpenAI did not finish processing the request (reason: #{finish_reason}). Please try again."
          return
        end

        content = response.dig("choices", 0, "message", "content")

        if AI.debug_mode?
          puts "==================== Raw content: ===================="
          puts content
          puts "======================================================"
        end

        parsed = TTY::Markdown.parse(content)
        puts parsed
      end

      private

      def send_messages(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:
      )
        messages = [
          {
            role: "system",
            content:
              "I will help you understand your Ruby application's behaviour."
          },
          {
            role: "user",
            content:
              generate_message(
                expression: expression,
                traces: traces,
                exception: exception,
                context_binding: context_binding,
                context_obj: context_obj
              )
          }
        ]

        if AI.debug_mode?
          puts "Sending to OpenAI..."
          puts "=== Messages ==="
          puts messages
        end

        puts "Getting response from OpenAI..."
        AI.ai_client.chat(
          parameters: {
            model: "gpt-3.5-turbo",
            messages: messages
          }
        )
      end

      def generate_message(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:
      )
        information =
          information_section(
            expression: expression,
            traces: traces,
            exception: exception,
            context_binding: context_binding,
            context_obj: context_obj
          )

        request = request_section(expression: expression)
        <<~MSG
          ### Information

          #{information}

          ### Request

          #{request}
        MSG
      end

      def information_section(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:
      )
        <<~MSG
          - The expression `#{expression}` is evaluated in the context of the following code's breakpoint (binding.irb) at line #{context_binding.source_location.last}:

          ```ruby
          #{File.read(context_binding.source_location.first)}
          ```

          - Here are the runtime traces when running the expression is evaluated (ignore if blank):

          #{traces}

          - The execution happened in the context of the object #{context_obj}
            - If a trace has `object-trace` header, that means the trace is about the execution of this object
            - If you see no `object-trace`, that means the object is not involved in the execution

          - The execution caused the following exception: #{exception} (ignore if blank)
            - Exception backtrace is: #{exception&.backtrace}
            - If you see multiple `exception-trace`, that means multiple exceptions were raised during the execution
            - But only the last trace s directly associated with the exception you see above
            - Use other exception traces to understand the execution flow in general and don't assume they have direct link to the exception above
        MSG
      end

      def request_section(expression:)
        <<~MSG
          Please respond in the following format, with markdown syntax, and use code highlight when appropriate:

          ```

          This is an analysis of the program's behaviour when running the expression `#{expression}` in the context of

          ```rb
          #{code_around_binding}
          ```

          ### Code Summary (skip if no program source code is given)

          <summary of the program's intended behaviour from the given code (ignore the breakpoint)>

          ### Execution Summary

          <summary of the program's actual behaviour from the given trace>

          ### Execution Details

          <detailed step-by-step explanation of the program's actual behaviour based on the source code and given trace>
          <strictly follow the below format>

          <example>
          1. The program started at line 1
          2. The program called method `foo` at line 2
          3. The program called method `bar` at line 3
          4. The trace shows that the program raised an exception at line 4
          </example>

          ### Debugging Suggestion (skip if no error is given)

          <potential causes of the error based on the program's execution details as explained in the previous section>
          <if you think the information is not sufficient, please explicit mention that and explain what information is missing>
        MSG
      end

      def code_around_binding
        original_colorize = IRB.conf[:USE_COLORIZE]
        IRB.conf[:USE_COLORIZE] = false
        code = irb_context.workspace.code_around_binding
      ensure
        IRB.conf[:USE_COLORIZE] = original_colorize
      end
    end
  end
end

IRB::AI.register_irb_commands
